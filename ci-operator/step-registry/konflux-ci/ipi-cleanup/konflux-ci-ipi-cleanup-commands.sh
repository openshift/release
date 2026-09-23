#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

AWS_ACCESS_KEY_ID=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-access-key-id)
AWS_SECRET_ACCESS_KEY=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-secret-access-key)
AWS_DEFAULT_REGION=us-west-2

cd "$(mktemp -d)"
curl -sSL https://raw.githubusercontent.com/konflux-ci/tekton-integration-catalog/main/scripts/ipi/delete-ipi-clusters.sh | bash
