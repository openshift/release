#!/usr/bin/env python3

# Script to revert a component in QCI to its previous version.
# When a faulty image is pushed to a component tag (e.g., ocp_4_17_component or ci_component_latest),
# this script finds the most recent _prune_ tag for that component and re-tags
# it back to the current tag, effectively reverting to the previous version.
#
# Supported tag formats:
#   - ocp_X_Y_component (e.g., ocp_4_17_my-component)
#   - ci_component_latest (e.g., ci_my-component_latest)
#
# Getting the OAuth token:
#   export QUAY_OAUTH_TOKEN=$(oc --context app.ci extract -n ci secret/qci-pruner-credentials --keys=token --to=-)
#
# Usage:
#   ./qci_component_revert.py --component ocp_4_17_my-component [--confirm]
#   ./qci_component_revert.py --component ci_my-component_latest [--confirm]
#
# The script will:
# 1. Find the current image for the specified tag
# 2. Find the most recent _prune_ tag for that component
# 3. Create a _prune_ tag with "_broken" suffix for the faulty current image
# 4. Re-tag the previous image back to the current tag
# 5. Delete the old _prune_ tag that was reverted from

import os
import sys
import json
import re
import argparse
import urllib.request
import logging
from typing import Optional, Dict, List
from datetime import datetime, timezone

QUAY_OAUTH_TOKEN_ENV_NAME = "QUAY_OAUTH_TOKEN"
REPOSITORY = "openshift/ci"

# Match QCI prune tags like "20240603235401_prune_ocp_4_17_component" or "20240603235401_prune_ci_component_latest"
prune_tag_match = re.compile(r"^(?P<year>\d\d\d\d)(?P<month>\d\d)(?P<day>\d\d)(?P<hour>\d\d)(?P<minute>\d\d)(?P<second>\d\d)_prune_(?P<ci_tag>.+)$")


def get_tag_info(repository: str, tag: str, token: str) -> Optional[Dict]:
    """Get information about a specific tag"""
    tag_url = f"https://quay.io/api/v1/repository/{repository}/tag/?specificTag={tag}"
    headers = {
        "Authorization": f"Bearer {token}"
    }

    request = urllib.request.Request(tag_url, method='GET')
    for key, value in headers.items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request) as response:
            response_data = response.read()
            if response.status == 200:
                data = json.loads(response_data)
                tags = data.get("tags", [])
                if tags:
                    return tags[0]
                return None
            logging.error("Failed to get tag info for '%s': %d %s", tag, response.status, response_data)
            return None
    except Exception:  # pylint: disable=broad-except
        logging.exception('Failed to get tag info for "%s"', tag)
        return None


def fetch_tags(repository: str, token: str, page: int = 1, like: Optional[str] = None) -> tuple:
    """Fetch tags from the quay.io repository with pagination"""
    like_adder = ''
    if like:
        like_adder = f'&filter_tag_name=like:{like}'
    tags_url = f"https://quay.io/api/v1/repository/{repository}/tag/?page={page}&limit=100&onlyActiveTags=true" + like_adder
    headers = {
        "Authorization": f"Bearer {token}"
    }

    request = urllib.request.Request(tags_url, method='GET')
    for key, value in headers.items():
        request.add_header(key, value)

    with urllib.request.urlopen(request) as response:
        response_data = response.read()
        if response.status == 200:
            data = json.loads(response_data)
            tags = data.get("tags", [])
            has_more = data.get("has_additional", False)
            return tags, has_more
        raise IOError(f"Failed to fetch tags: {response.status} {response_data}")


def create_tag(repository: str, tag: str, manifest_digest: str, token: str) -> bool:
    """Create a new tag pointing to a specific manifest digest"""
    tag_url = f"https://quay.io/api/v1/repository/{repository}/tag/{tag}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

    payload = json.dumps({
        "manifest_digest": manifest_digest
    }).encode('utf-8')

    request = urllib.request.Request(tag_url, data=payload, method='PUT')
    for key, value in headers.items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request) as response:
            response_data = response.read()
            if response.status in [200, 201, 204]:
                logging.info("Successfully created tag '%s' pointing to %s", tag, manifest_digest)
                return True
            logging.error("Failed to create tag '%s': %d %s", tag, response.status, response_data)
            return False
    except Exception:  # pylint: disable=broad-except
        logging.exception('Failed to create tag "%s"', tag)
        return False


def delete_tag(repository: str, tag: str, token: str) -> bool:
    """Delete a tag from the repository"""
    tag_url = f"https://quay.io/api/v1/repository/{repository}/tag/{tag}"
    headers = {
        "Authorization": f"Bearer {token}"
    }

    request = urllib.request.Request(tag_url, method='DELETE')
    for key, value in headers.items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request) as response:
            response_data = response.read()
            if response.status in [200, 201, 204]:
                logging.info("Successfully deleted tag '%s'", tag)
                return True
            logging.error("Failed to delete tag '%s': %d %s", tag, response.status, response_data)
            return False
    except Exception:  # pylint: disable=broad-except
        logging.exception('Failed to delete tag "%s"', tag)
        return False


def find_prune_tags_for_component(component_tag: str, token: str) -> List[Dict]:
    """Find all _prune_ tags for a given component, sorted by date (newest first)"""
    prune_tags = []

    # Search for tags matching the pattern
    search_pattern = f"_prune_{component_tag}"
    logging.info("Searching for prune tags matching pattern: *%s", search_pattern)

    page = 1
    has_more = True

    while has_more:
        try:
            tags, has_more = fetch_tags(REPOSITORY, token, page, like=search_pattern)
            for tag in tags:
                tag_name = tag['name']
                match = prune_tag_match.match(tag_name)
                if match and match.group('ci_tag') == component_tag:
                    year = int(match.group('year'))
                    month = int(match.group('month'))
                    day = int(match.group('day'))
                    hour = int(match.group('hour'))
                    minute = int(match.group('minute'))
                    second = int(match.group('second'))

                    tag_date = datetime(year, month, day, hour, minute, second)
                    prune_tags.append({
                        'name': tag_name,
                        'date': tag_date,
                        'manifest_digest': tag.get('manifest_digest'),
                        'image_id': tag.get('image_id')
                    })

            page += 1
        except Exception:  # pylint: disable=broad-except
            logging.exception("Error fetching tags")
            break

    # Sort by date, newest first
    prune_tags.sort(key=lambda x: x['date'], reverse=True)
    return prune_tags


def get_token_from_args_or_env(token_arg: Optional[str]) -> str:
    """Get OAuth token from arguments or environment variable"""
    token = token_arg or os.getenv(QUAY_OAUTH_TOKEN_ENV_NAME)
    if not token:
        logging.error('OAuth token is required')
        sys.exit(1)
    return token


def fetch_current_tag_info(component_tag: str, token: str) -> Dict:
    """Fetch and validate current tag information"""
    logging.info("Fetching current tag information...")
    current_tag_info = get_tag_info(REPOSITORY, component_tag, token)

    if not current_tag_info:
        logging.error("Component tag '%s' not found in repository", component_tag)
        sys.exit(1)

    current_manifest = current_tag_info.get('manifest_digest')
    logging.info("Current tag '%s' points to manifest: %s", component_tag, current_manifest)
    return current_tag_info


def fetch_and_display_prune_tags(component_tag: str, token: str) -> List[Dict]:
    """Find and display available prune tags for component"""
    logging.info("Searching for previous versions (prune tags)...")
    prune_tags = find_prune_tags_for_component(component_tag, token)

    if not prune_tags:
        logging.error("No previous versions found for component '%s'", component_tag)
        logging.error("Cannot revert - no _prune_ tags exist for this component")
        sys.exit(1)

    logging.info("Found %d previous version(s)", len(prune_tags))

    # Display the most recent prune tags
    display_count = min(3, len(prune_tags))
    logging.info("Most recent %d version(s):", display_count)
    for i, tag in enumerate(prune_tags[:display_count]):
        logging.info("  %d. %s (date: %s, manifest: %s)",
                     i + 1, tag['name'], tag['date'], tag['manifest_digest'])

    return prune_tags


def select_version_to_revert(prune_tags: List[Dict], version_number: int) -> Dict:
    """Select which version to revert to based on user input"""
    version_index = version_number - 1

    if version_index < 0 or version_index >= len(prune_tags):
        logging.error("Invalid version number. Must be between 1 and %d", len(prune_tags))
        sys.exit(1)

    return prune_tags[version_index]


def display_revert_plan(component_tag: str, current_manifest: str, revert_to: Dict):
    """Display the revert plan to the user"""
    revert_manifest = revert_to['manifest_digest']
    revert_tag_name = revert_to['name']

    logging.info("=== Revert Plan ===")
    logging.info("Will revert '%s' to:", component_tag)
    logging.info("  Previous tag: %s", revert_tag_name)
    logging.info("  Date: %s", revert_to['date'])
    logging.info("  Manifest: %s", revert_manifest)

    if current_manifest == revert_manifest:
        logging.warning("Current tag already points to this manifest!")
        logging.warning("No revert necessary.")
        sys.exit(0)

    prune_tag_for_current = get_broken_prune_tag(component_tag)
    logging.info("Will also create prune tag for current (faulty) version:")
    logging.info("  New prune tag: %s", prune_tag_for_current)
    logging.info("  Manifest: %s", current_manifest)

    logging.info("Will delete old prune tag after revert:")
    logging.info("  Tag to delete: %s", revert_tag_name)

def get_broken_prune_tag(component_tag):
    now = datetime.now(timezone.utc)
    prune_tag_for_current = f"{now.strftime('%Y%m%d%H%M%S')}_prune_{component_tag}_broken"
    return prune_tag_for_current


def prune_current_broken(component_tag: str, current_manifest: str, token: str) -> None:
    """Create a prune tag for the current (faulty) version"""
    prune_tag_for_current = get_broken_prune_tag(component_tag)
    logging.info("Creating prune tag for current (faulty) version...")
    if create_tag(REPOSITORY, prune_tag_for_current, current_manifest, token):
        logging.info("Successfully preserved current version as '%s'", prune_tag_for_current)
    else:
        logging.error("Failed to create prune tag for current version")
        logging.error("Aborting revert.")
        sys.exit(1)


def execute_revert(component_tag: str, current_manifest: str, revert_to: Dict, token: str) -> None:
    """Execute the actual revert operation"""
    revert_manifest = revert_to['manifest_digest']

    logging.info("Reverting '%s' to previous version...", component_tag)
    if create_tag(REPOSITORY, component_tag, revert_manifest, token):
        logging.info("=== SUCCESS ===")
        logging.info("Component '%s' has been reverted to version from %s",
                     component_tag, revert_to['date'])
        logging.info("Reverted from manifest: %s", current_manifest)
        logging.info("Reverted to manifest:   %s", revert_manifest)
    else:
        logging.error("Failed to revert component tag")
        sys.exit(1)


def run(args):
    """Main entry point for the revert script"""
    token = get_token_from_args_or_env(args.token)
    component_tag = args.component

    logging.info("=== QCI Component Reverter ===")
    logging.info("Component tag: %s", component_tag)
    logging.info("Repository: %s", REPOSITORY)

    current_tag_info = fetch_current_tag_info(component_tag, token)
    current_manifest = current_tag_info.get('manifest_digest')
    prune_tags = fetch_and_display_prune_tags(component_tag, token)
    revert_to = select_version_to_revert(prune_tags, args.version)
    display_revert_plan(component_tag, current_manifest, revert_to)

    if not args.confirm:
        logging.warning("=== DRY RUN MODE ===")
        logging.warning("Add --confirm to actually perform the revert")
        sys.exit(0)

    logging.info("=== Executing Revert ===")
    prune_current_broken(component_tag, current_manifest, token)
    execute_revert(component_tag, current_manifest, revert_to, token)

    revert_tag_name = revert_to['name']
    logging.info("Deleting old prune tag '%s'...", revert_tag_name)
    if delete_tag(REPOSITORY, revert_tag_name, token):
        logging.info("Successfully deleted old prune tag '%s'", revert_tag_name)
    else:
        logging.warning("Failed to delete old prune tag '%s', but revert was successful", revert_tag_name)


logging.basicConfig(
    level=logging.INFO,
    format='%(levelname)s - %(message)s',
)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description="Revert a QCI component to its previous version",
        epilog="""
Examples:
  # Dry run - see what would be reverted (ocp format)
  ./qci_component_revert.py --component ocp_4_17_my-component

  # Dry run - see what would be reverted (ci format)
  ./qci_component_revert.py --component ci_my-component_latest

  # Actually revert to most recent previous version (automatically creates a _broken prune tag for current version)
  ./qci_component_revert.py --component ocp_4_17_my-component --confirm
  ./qci_component_revert.py --component ci_my-component_latest --confirm

  # Revert to the 2nd most recent version
  ./qci_component_revert.py --component ocp_4_17_my-component --version 2 --confirm
        """,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument(
        '--component',
        type=str,
        required=True,
        help='Component tag to revert (e.g., ocp_4_17_my-component or ci_my-component_latest)'
    )
    parser.add_argument(
        '--token',
        type=str,
        help=f'quay.io oauth application token (or set {QUAY_OAUTH_TOKEN_ENV_NAME} environment variable)'
    )
    parser.add_argument(
        '--version',
        type=int,
        default=1,
        help='Which previous version to revert to (1 = most recent, 2 = second most recent, etc.). Default: 1'
    )
    parser.add_argument(
        '--confirm',
        action='store_true',
        help='Actually perform the revert (without this flag, only shows what would be done)'
    )

    run(parser.parse_args())
    sys.exit(0)
