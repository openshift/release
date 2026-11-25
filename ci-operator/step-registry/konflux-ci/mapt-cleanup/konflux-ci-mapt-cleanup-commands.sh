#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

AWS_ACCESS_KEY_ID=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-access-key-id)
AWS_SECRET_ACCESS_KEY=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-secret-access-key)
export AWS_REGION=us-east-1

cd "$(mktemp -d)"
curl -sSL https://raw.githubusercontent.com/konflux-ci/tekton-integration-catalog/main/scripts/mapt/delete-mapt-clusters.sh | bash
