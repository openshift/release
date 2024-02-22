#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

GITHUB_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-github-secret/GITHUB_AUTH_TOKEN)

export GITHUB_AUTH_TOKEN

./scripts/vale-review.sh

