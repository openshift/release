#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

RELEASE_REPO=${RELEASE_REPO:-.}

echo >&2 "$(date --iso-8601=seconds) Executing sync-rover-groups validation"
out=$(sync-rover-groups --manifest-dir=$RELEASE_REPO/clusters --config-file=$RELEASE_REPO/core-services/sync-rover-groups/_config.yaml --log-level=debug --print-config)

# && true avoids the abrupt script termination because diff return code.
# Exit status is 0 if inputs are the same, 1 if different, 2 if trouble.
echo "$out" | diff - $RELEASE_REPO/core-services/sync-rover-groups/_config.yaml -U10 && true
if [[ $? -ne 0 ]]; then
  echo "ERROR: Changes in release/core-services/sync-rover-groups/_config.yaml ^^^"
  echo "ERROR: Running sync-rover-groups --validate results in changes"
  echo "ERROR: To avoid breaking openshift/release for everyone you should"
  echo "ERROR: fix sync-rover-groups/_config.yaml, removing extra spaces"
  echo "ERROR: comments and ordering the keys alphabetically."
  exit 1
else
  echo "Running sync-rover-groups --validate does not result in changes, no followups needed"
fi
