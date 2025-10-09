#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

RELEASE_REPO=${RELEASE_REPO:-.}

echo >&2 "$(date -u +'%Y-%m-%dT%H:%M:%S%z') Executing prow-job-dispatcher validation"
set +e
prow-job-dispatcher -validate-only  --cluster-config-path=$RELEASE_REPO/core-services/sanitize-prow-jobs/_clusters.yaml
exit_code=$?
set -e

if [[ $exit_code -ne 0 ]]; then
  echo "ERROR: Changes in release/core-services/sanitize-prow-jobs/_clusters.yaml ^^^"
  echo "ERROR: Running prow-job-dispatcher --validate results in changes"
  echo "ERROR: To avoid breaking openshift/release for everyone you should"
  echo "ERROR: fix sanitize-prow-jobs/_clusters.yaml, removing extra spaces"
  echo "ERROR: comments and ordering the keys alphabetically."
  exit 1
else
  echo "Running prow-job-dispatcher --validate does not result in changes, no followups needed"
fi
