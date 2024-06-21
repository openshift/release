#!/bin/bash

# We don't care if the GH comment step fails
# set -o nounset
# set -o errexit
# set -o pipefail
# set -o verbose

GITHUB_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-vale-github-secret/GITHUB_AUTH_TOKEN)

export GITHUB_AUTH_TOKEN

vale sync

./scripts/vale-review.sh $PULL_NUMBER $PULL_PULL_SHA

