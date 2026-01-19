#!/usr/bin/env python3

# https://docs.google.com/document/d/1nuLA2q4eqm4_cIPgRzVGV21IJEcqc4IvkMn_LxvACt4/edit#heading=h.66y4kqbj468a
# describes the QCI registry and our work to use it as the source of truth for promoted images.
# When using app.ci as our source of truth, pruning was automatic. Images that are
# no longer referred to by an ImageStream would be periodically garbage collected
# by the platform. ImageStream references included a brief history images previously
# referred to by tags.
# Due to this history, an image referenced by istag ocp/4.17:component would not immediately
# be garbage collected when a new image was pushed to the tag.
# In contrast, quay.io aggressively garbage collects any image that does not have a
# tag associated with it. This leads to a problem using quay.io for our CI registry.
# Refer to the document for details, but in short, when promotion occurs, ci-operator
# will push an image destined for ocp/4.17:component to quay.io/openshift/ci:ocp_4.17_component .
# When another merge occurs for that component and a new image needs to be promoted,
# the quay.io/openshift/ci:ocp_4.17_component tag needs to be overwritten.
# If the tag was overwritten, and it was the only tag pointing to the older image, the
# older image would be garbage collected immediately. This would interfere with test jobs
# using references to that older image.
# To prevent this race condition, ci-operator will create a new tag for the old image PRIOR
# to promoting the new image.
# The tag will be of the form quay.io/openshift/ci:YYYYMMDDHHMMSS_prune_<tag_name> .
# This tag will prevent quay.io from garbage collecting the old image until it is removed.
# The pruner works by looking for "_prune_" tags that are over X days old. The old tag
# is removed and the old image will finally be garbage collected.
#
# RELEASE PAYLOAD PRESERVATION:
# The pruner manages preservation of release payload component images through
# cooperation with the release controller.
#
# Release Controller Responsibilities:
# 1. When creating a release payload, the release controller pushes a tag with the pattern:
#    rc_payload__{payload_version}
#    Example: rc_payload__4.4.0-0.nightly-s390x-2021-03-16-171946
#
# 2. When the release controller wants to remove a payload, it pushes a removal request tag:
#    remove__rc_payload__{payload_version}
#    Example: remove__rc_payload__4.4.0-0.nightly-s390x-2021-03-16-171946
#
# Pruner Responsibilities:
# 1. During tag iteration, the pruner discovers all rc_payload__ tags pushed by the release
#    controller and checks if they have a corresponding __preserved marker tag.
#
# 2. For unpreserved payloads (those without a preserved__ marker), the pruner:
#    a. Runs 'oc adm release info' to extract component image references from the payload
#    b. Creates preservation tags for each component from quay.io/openshift/ci:
#       rc_payload__{payload_version}__component__{component_name}
#    c. After successfully preserving all components, creates a marker tag:
#       preserved__rc_payload__{payload_version}
#    This marker prevents re-processing the same payload on subsequent pruner runs.
#
# 3. When a remove__rc_payload__ tag is found, the pruner:
#    a. Deletes the main rc_payload__{payload_version} tag
#    b. Deletes the preserved__rc_payload__{payload_version} marker (if it exists)
#    c. Deletes all rc_payload__{payload_version}__component__* tags
#    d. After successful removal, deletes the remove__rc_payload__ request tag itself
#       (typically on the next pruner invocation)
#
# 4. The pruner skips preservation for any payload with a pending removal request to avoid
#    race conditions where newly created component tags might not be properly cleaned up.
#
# This cooperative model ensures that release payload component images are protected from
# garbage collection while they are referenced by active release payloads, and are properly
# cleaned up when payloads are retired.

import time
import os
import sys
import json
import re
import argparse
import urllib.request
import subprocess
import logging
from typing import Optional, Set, Dict, List
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

QUAY_OAUTH_TOKEN_ENV_NAME = "QUAY_OAUTH_TOKEN"

# Repository and registry constants
QUAY_CI_REPO = "openshift/ci"
QUAY_REGISTRY = f"quay.io/{QUAY_CI_REPO}"
QUAY_PROXY_REGISTRY = f"quay-proxy.ci.openshift.org/{QUAY_CI_REPO}"

# Tag pattern constants for release payloads
RC_PAYLOAD_PREFIX = "rc_payload__"
REMOVE_RC_PAYLOAD_PREFIX = "remove__rc_payload__"
PRESERVED_RC_PAYLOAD_PREFIX = "preserved__rc_payload__"
COMPONENT_INFIX = "__component__"

# Match QCI sha tags like "20240603235401_prune_ci_a_latest"
prune_tag_match = re.compile(r"^(?P<year>\d\d\d\d)(?P<month>\d\d)(?P<day>\d\d)(?P<hour>\d\d)(?P<minute>\d\d)(?P<second>\d\d)_prune_(?P<ci_tag>.+)$")

# Match release payload tags like "rc_payload__4.4.0-0.nightly-s390x-2021-03-16-171946"
rc_payload_tag_match = re.compile(rf"^{re.escape(RC_PAYLOAD_PREFIX)}(?P<version>.+)$")

# Match preserved marker tags like "preserved__rc_payload__4.4.0-0.nightly-s390x-2021-03-16-171946"
rc_payload_preserved_match = re.compile(rf"^{re.escape(PRESERVED_RC_PAYLOAD_PREFIX)}(?P<version>.+)$")

# Match removal request tags like "remove__rc_payload__4.4.0-0.nightly-s390x-2021-03-16-171946"
remove_rc_payload_match = re.compile(rf"^{re.escape(REMOVE_RC_PAYLOAD_PREFIX)}(?P<version>.+)$")

# Match component preservation tags like "rc_payload__4.4.0-0.nightly-s390x-2021-03-16-171946__component__etcd"
rc_payload_component_match = re.compile(rf"^{re.escape(RC_PAYLOAD_PREFIX)}(?P<version>.+){re.escape(COMPONENT_INFIX)}(?P<component>.+)$")


def create_tag(repository: str, tag: str, manifest_digest: str, token: str):
    """Create a tag in a quay.io repository pointing to a specific manifest digest"""
    # PUT /api/v1/repository/{repository}/tag/{tag}
    create_url = f"https://quay.io/api/v1/repository/{repository}/tag/{tag}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

    # The manifest_digest should be in the form "sha256:..."
    data = json.dumps({
        "manifest_digest": manifest_digest
    }).encode('utf-8')

    request = urllib.request.Request(create_url, data=data, method='PUT')
    for key, value in headers.items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request) as response:
            response_data = response.read()
            if response.status not in [200, 201, 204]:
                logging.error("Failed to create tag '%s': %d %s", tag, response.status, response_data)
                return False
            return True
    except Exception:  # pylint: disable=broad-except
        logging.exception('Failed to create tag "%s"', tag)
        return False


def delete_tag(repository: str, tag: str, token: str) -> bool:
    """Delete a tag from a quay.io repository. Returns True on success, False on failure."""
    delete_url = f"https://quay.io/api/v1/repository/{repository}/tag/{tag}"
    headers = {
        "Authorization": f"Bearer {token}"
    }

    request = urllib.request.Request(delete_url, method='DELETE')
    for key, value in headers.items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request) as response:
            response_data = response.read()
            if response.status == 204:
                logging.info('Successfully deleted %s', tag)
                return True
            logging.error("Failed to delete tag '%s': %d %s", tag, response.status, response_data)
            return False
    except Exception:  # pylint: disable=broad-except
        logging.exception('Failed to delete tag "%s"', tag)
        return False


def fetch_tags(repository: str, token: str, page: int = 1, like: Optional[str] = None):
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


def get_tag_manifest_digest(repository: str, tag: str, token: str) -> Optional[str]:
    """Get the manifest digest for a specific tag"""
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
                if tags and len(tags) > 0:
                    return tags[0].get("manifest_digest")
    except Exception:  # pylint: disable=broad-except
        logging.exception('Failed to get manifest digest for tag "%s"', tag)
    return None


def get_release_component_images(payload_pullspec: str) -> List[Dict[str, str]]:
    """Use 'oc adm release info' to get component images from a release payload"""
    components = []

    try:
        cmd = ["oc", "adm", "release", "info", "--output=json", payload_pullspec]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=300)

        data = json.loads(result.stdout)
        tags = data.get("references", {}).get("spec", {}).get("tags", [])

        for tag_entry in tags:
            tag_name = tag_entry.get("name", "")
            from_ref = tag_entry.get("from", {}).get("name", "")

            # Extract registry, repo, and digest
            # Format: registry.ci.openshift.org/ocp/4.11-2025-09-22-212223@sha256:...
            if from_ref and "@sha256:" in from_ref:
                parts = from_ref.split("@")
                image_ref = parts[0]
                digest = parts[1]

                components.append({
                    "tag_name": tag_name,
                    "image_ref": image_ref,
                    "digest": digest,
                    "full_ref": from_ref
                })

        logging.debug("Found %d component images in payload %s", len(components), payload_pullspec)

    except subprocess.TimeoutExpired:
        logging.error("Timeout running 'oc adm release info' for %s", payload_pullspec)
    except subprocess.CalledProcessError as e:
        logging.error("Failed to run 'oc adm release info' for %s: %s", payload_pullspec, e.stderr)
    except Exception:  # pylint: disable=broad-except
        logging.exception("Error getting release info for %s", payload_pullspec)

    return components


def preserve_release_components(payload_version: str, payload_tag: str, token: str, confirm: bool) -> bool:  # pylint: disable=too-many-statements
    """Preserve component images for a release payload"""
    logging.info("Preserving components for release payload: %s", payload_version)

    # Construct the pullspec for the payload
    payload_pullspec = f"{QUAY_REGISTRY}:{payload_tag}"

    # Get component images
    components = get_release_component_images(payload_pullspec)

    if not components:
        logging.warning("No components found for %s", payload_version)
        return False

    preserved_count = 0
    for component in components:
        # Only preserve if the component is from quay.io/openshift/ci or quay-proxy.ci.openshift.org/openshift/ci
        image_ref = component["image_ref"]
        if not (image_ref.startswith(QUAY_REGISTRY) or
                image_ref.startswith(QUAY_PROXY_REGISTRY)):
            continue

        # Use the tag name from the release payload metadata
        tag_name = component["tag_name"]

        # Create preservation tag
        component_tag = f"{RC_PAYLOAD_PREFIX}{payload_version}{COMPONENT_INFIX}{tag_name}"
        digest = component["digest"]

        if confirm:
            if create_tag(QUAY_CI_REPO, component_tag, digest, token):
                preserved_count += 1
                logging.debug("Preserved component %s with tag %s", tag_name, component_tag)
            else:
                logging.error("Failed to preserve component %s", tag_name)
        else:
            logging.debug("Would preserve component %s with tag %s", tag_name, component_tag)
            preserved_count += 1

    logging.info("Preserved %d/%d components for %s", preserved_count, len(components), payload_version)

    # Create the preserved__ marker tag
    if confirm and preserved_count > 0:
        # Get the manifest digest of the payload
        payload_digest = get_tag_manifest_digest(QUAY_CI_REPO, payload_tag, token)
        if payload_digest:
            preserved_tag = f"{PRESERVED_RC_PAYLOAD_PREFIX}{payload_version}"
            if create_tag(QUAY_CI_REPO, preserved_tag, payload_digest, token):
                logging.info("Created preservation marker tag: %s", preserved_tag)
                return True
            logging.error("Failed to create preservation marker tag: %s", preserved_tag)
        else:
            logging.error("Could not get manifest digest for payload tag: %s", payload_tag)

    return preserved_count > 0


def run(args, start_time):  # pylint: disable=too-many-statements,redefined-outer-name

    token = args.token
    if not token:
        token = os.getenv(QUAY_OAUTH_TOKEN_ENV_NAME)

    if not token:
        logging.error('OAuth token is required')
        sys.exit(1)

    confirm = args.confirm
    ttl_days = args.ttl_days

    # Fetch all tags with pagination
    page = 1
    has_more = True

    prune_target_tags = set()
    tag_count = 0
    mod_by = 5

    # Track release payload tags
    rc_payload_tags: Dict[str, str] = {}  # version -> tag
    preserved_versions: Set[str] = set()
    remove_requests: Set[str] = set()  # versions to remove
    component_tags: Dict[str, List[str]] = {}  # version -> list of component tag names

    # Executor for concurrent tag deletions (up to 100 simultaneous requests)
    delete_executor = ThreadPoolExecutor(max_workers=100)
    delete_futures = []  # List of futures

    while has_more:
        retries = 5
        while True:
            try:
                tags, has_more = fetch_tags(QUAY_CI_REPO, token, page)
                break
            except Exception:  # pylint: disable=broad-except
                logging.exception("Error retrieving tags")
                if retries == 0:
                    raise
                logging.info('Retrying in 1 minute..')
                time.sleep(60)
                retries -= 1

        # Iterate through tags and delete those that match the pattern "YYMMDDHHMMSS_prune_%" and collecting payload information
        for tag in tags:
            tag_count += 1
            image_tag = tag['name']

            if tag_count % mod_by == 0:
                mod_by = min(mod_by * 2, 1000)
                logging.info('%d tags have been checked', tag_count)

            # Check for rc_payload__ tags
            payload_match = rc_payload_tag_match.match(image_tag)
            if payload_match:
                version = payload_match.group('version')
                rc_payload_tags[version] = image_tag
                continue

            # Check for preserved marker tags
            preserved_match = rc_payload_preserved_match.match(image_tag)
            if preserved_match:
                version = preserved_match.group('version')
                preserved_versions.add(version)
                continue

            # Check for removal requests
            remove_match = remove_rc_payload_match.match(image_tag)
            if remove_match:
                version = remove_match.group('version')
                remove_requests.add(version)
                continue

            # Check for component preservation tags
            component_match = rc_payload_component_match.match(image_tag)
            if component_match:
                version = component_match.group('version')
                if version not in component_tags:
                    component_tags[version] = []
                component_tags[version].append(image_tag)
                continue

            # Check for prune tags
            match = prune_tag_match.match(image_tag)
            if match:
                year = int(match.group('year'))
                month = int(match.group('month'))
                day = int(match.group('day'))
                prune_tag_date = datetime(year, month, day)

                date_difference = start_time - prune_tag_date
                days_difference = date_difference.days
                if days_difference > ttl_days and image_tag not in prune_target_tags:
                    prune_target_tags.add(image_tag)
                    if confirm:
                        delete_futures.append(delete_executor.submit(delete_tag, QUAY_CI_REPO, image_tag, token))
                    else:
                        logging.debug('Would have removed %s', image_tag)

        page += 1

    # Wait for all prune delete operations to complete
    prune_success_count = 0
    if delete_futures:
        logging.info('Waiting for %d prune delete operations to complete...', len(delete_futures))
        for future in delete_futures:
            if future.result():  # Returns True on success
                prune_success_count += 1
        delete_futures.clear()

    # Process release payload preservation
    logging.info("Processing release payload preservation...")
    logging.info("Found %d rc_payload__ tags", len(rc_payload_tags))
    logging.info("Found %d preserved markers", len(preserved_versions))

    payloads_needing_preservation = 0
    payloads_preserved = 0

    for version, payload_tag in rc_payload_tags.items():
        # Skip preservation if there's a pending removal request
        if version in remove_requests:
            logging.info("Skipping preservation for %s - has pending removal request", version)
            continue

        if version not in preserved_versions:
            payloads_needing_preservation += 1
            logging.info("Release payload %s has not been preserved yet", version)
            if preserve_release_components(version, payload_tag, token, confirm):
                payloads_preserved += 1
        else:
            logging.debug("Release payload %s already preserved", version)

    # Process removal requests
    removal_requests_processed = 0
    removal_tags_target = 0
    removal_success_count = 0

    if remove_requests:
        logging.info("Processing %d removal requests...", len(remove_requests))

        for version in remove_requests:
            if version in rc_payload_tags:
                logging.info("Processing removal request for %s", version)
                removal_requests_processed += 1

                # Find all tags related to this payload (payload tag + preserved marker + components)
                tags_to_remove = []

                # Add the main payload tag
                tags_to_remove.append(f"{RC_PAYLOAD_PREFIX}{version}")

                # Add the preserved marker if it exists
                if version in preserved_versions:
                    tags_to_remove.append(f"{PRESERVED_RC_PAYLOAD_PREFIX}{version}")

                # Add component tags if they exist
                if version in component_tags:
                    tags_to_remove.extend(component_tags[version])
                    logging.info("Found %d component tags for %s", len(component_tags[version]), version)

                logging.info("Found %d tags to remove for %s", len(tags_to_remove), version)
                removal_tags_target += len(tags_to_remove)

                # Remove all related tags
                if confirm:
                    for tag_to_remove in tags_to_remove:
                        delete_futures.append(delete_executor.submit(delete_tag, QUAY_CI_REPO, tag_to_remove, token))
                else:
                    for tag_to_remove in tags_to_remove:
                        logging.info("Would remove tag: %s", tag_to_remove)
            else:
                # No matching rc_payload__ tag found, so we can delete the remove__ request
                remove_tag = f"{REMOVE_RC_PAYLOAD_PREFIX}{version}"
                logging.info("No rc_payload__ tag found for %s, removing request tag", version)
                removal_tags_target += 1

                if confirm:
                    delete_futures.append(delete_executor.submit(delete_tag, QUAY_CI_REPO, remove_tag, token))
                else:
                    logging.info("Would remove request tag: %s", remove_tag)

        # Wait for all removal delete operations to complete
        if delete_futures:
            logging.info('Waiting for %d removal delete operations to complete...', len(delete_futures))
            for future in delete_futures:
                if future.result():  # Returns True on success
                    removal_success_count += 1
            delete_futures.clear()

    finish_time = datetime.now()
    logging.info('Duration: %s', finish_time - start_time)
    logging.info('Total tags scanned: %d', tag_count)
    logging.info('Tags targeted for pruning: %d', len(prune_target_tags))
    if confirm:
        logging.info('Tags successfully pruned: %d', prune_success_count)
    logging.info('Release payloads needing preservation: %d', payloads_needing_preservation)
    if confirm:
        logging.info('Release payloads preserved: %d', payloads_preserved)
    else:
        logging.info('Release payloads that would be preserved: %d', payloads_needing_preservation)
    logging.info('Removal requests processed: %d', removal_requests_processed)
    logging.info('Release payload tags targeted for removal: %d', removal_tags_target)
    if confirm:
        logging.info('Release payload tags successfully removed: %d', removal_success_count)

    # Cleanup executor
    delete_executor.shutdown(wait=False)

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s', datefmt='%Y-%m-%dT%H:%M:%S')

if __name__ == '__main__':
    start_time = datetime.now()
    parser = argparse.ArgumentParser(
        description=f"Prune old tags from {QUAY_REGISTRY} repository and preserve release payloads"
    )

    parser.add_argument('--token', type=str, help=f'quay.io oauth application token (or set {QUAY_OAUTH_TOKEN_ENV_NAME} environment variable)')
    parser.add_argument('--ttl-days', type=int, default=5, help='Only prune tags older than this (defaults to 5; -1 for all prunable tags)')
    parser.add_argument('--confirm', action='store_true', help='Actually delete and refresh tags')

    run(parser.parse_args(), start_time)
    sys.exit(0)
