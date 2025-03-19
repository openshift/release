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

import time
import os
import sys
import json
import re
import argparse
import urllib.request
import logging
from typing import Optional
from datetime import datetime

QUAY_OAUTH_TOKEN_ENV_NAME = "QUAY_OAUTH_TOKEN"


# Match QCI sha tags like "20240603235401_prune_ci_a_latest"
prune_tag_match = re.compile(r"^(?P<year>\d\d\d\d)(?P<month>\d\d)(?P<day>\d\d)(?P<hour>\d\d)(?P<minute>\d\d)(?P<second>\d\d)_prune_(?P<ci_tag>.+)$")


def delete_tag(repository: str, tag: str, token: str):
    """Delete a tag from a quay.io repository"""
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
            if response.status != 204:
                logging.error("Failed to delete tag '%s': %d %s", tag, response.status, response_data)
    except Exception:  # pylint: disable=broad-except
        logging.exception('Failed to delete tag "%s"', tag)


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


def run(args):

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
    pruned_tags = set()
    tag_count = 0
    mod_by = 5
    while has_more:
        retries = 5
        while True:
            try:
                tags, has_more = fetch_tags('openshift/ci', token, page)
                break
            except Exception:  # pylint: disable=broad-except
                logging.exception("Error retrieving tags")
                if retries == 0:
                    raise
                logging.info('Retrying in 1 minute..')
                time.sleep(60)
                retries -= 1

        # Iterate through tags and delete those that match the pattern "YYMMDDHHMMSS_prune_%"
        for tag in tags:
            tag_count += 1
            image_tag = tag['name']

            if tag_count % mod_by == 0:
                mod_by = min(mod_by * 2, 1000)
                logging.info('%d tags have been checked', tag_count)

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
                        try:
                            delete_tag('openshift/ci', tag=image_tag, token=token)
                            logging.debug('Removed %s', image_tag)
                            pruned_tags.add(image_tag)
                        except Exception:  # pylint: disable=broad-except
                            logging.exception('Error while trying to delete tag %s', image_tag)
                    else:
                        logging.debug('Would have removed %s', image_tag)

        page += 1

    finish_time = datetime.now()
    logging.info('Duration: %s', finish_time - start_time)
    logging.info('Total tags scanned: %d', tag_count)
    logging.info('Tags pruned (if --confirm): %d', len(prune_target_tags))
    logging.info('Tags actually pruned: %d', len(pruned_tags))

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s', datefmt='%Y-%m-%dT%H:%M:%S')

if __name__ == '__main__':
    start_time = datetime.now()
    parser = argparse.ArgumentParser(description="Process some optional arguments.")

    parser.add_argument('--token', type=str, help=f'quay.io oauth application token (or set {QUAY_OAUTH_TOKEN_ENV_NAME} environment variable)')
    parser.add_argument('--ttl-days', type=int, default=5, help='Only prune tags older than this (defaults to 5; -1 for all prunable tags)')
    parser.add_argument('--confirm', action='store_true', help='Actually delete and refresh tags')

    run(parser.parse_args())
    sys.exit(0)
