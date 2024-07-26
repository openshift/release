#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

PR_AUTHOR=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].author')

if [ "$PR_AUTHOR" == "openshift-cherrypick-robot" ]; then
  echo "openshift-cherrypick-robot PRs don't need a full docs build."
  exit 0
fi

curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/check-rn-link-perms.sh > scripts/check-rn-link-perms.sh

./scripts/check-rn-link-perms.sh
