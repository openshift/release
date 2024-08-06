#!/bin/bash

# We don't care if the GH comment step fails
# set -o nounset
# set -o errexit
# set -o pipefail
# set -o verbose

PR_AUTHOR=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].author')

if [ "$PR_AUTHOR" == "openshift-cherrypick-robot" ]; then
  echo "openshift-cherrypick-robot PRs don't need a full docs build."
  exit 0
fi

curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/prow-vale-review.sh > scripts/prow-vale-review.sh

GITHUB_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-vale-github-secret/GITHUB_AUTH_TOKEN)

export GITHUB_AUTH_TOKEN

vale sync

./scripts/prow-vale-review.sh $PULL_NUMBER $PULL_PULL_SHA

