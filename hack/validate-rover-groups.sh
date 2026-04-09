#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

RELEASE_REPO=${RELEASE_REPO:-.}

echo >&2 "$(date -u +'%Y-%m-%dT%H:%M:%S%z') Executing sync-rover-groups validation"

# Run sync-rover-groups and capture output
if ! out=$(sync-rover-groups --manifest-dir=$RELEASE_REPO/clusters --config-file=$RELEASE_REPO/core-services/sync-rover-groups/_config.yaml --log-level=debug --print-config 2>&1); then
    echo "ERROR: Config file has syntax errors or invalid fields"
    echo "$out"
    exit 1
fi

# Check if normalized output differs from current file
if ! echo "$out" | diff - $RELEASE_REPO/core-services/sync-rover-groups/_config.yaml -U10 >/dev/null; then
  echo "$out" | diff - $RELEASE_REPO/core-services/sync-rover-groups/_config.yaml -U10 || true
  echo ""
  echo "ERROR: Config file format doesn't match normalized format"
  echo "  (+ means current file, - means normalized)."
  echo "The file contains formatting issues like extra spaces,"
  echo "comments, or incorrect key ordering (should be alphabetical)."
  echo "Please fix it to avoid breaking openshift/release for everyone."
  echo "You can use the diff above to see the exact changes needed."
  exit 1
else
  echo "Success: No breaking changes detected, no follow-ups needed"
fi
