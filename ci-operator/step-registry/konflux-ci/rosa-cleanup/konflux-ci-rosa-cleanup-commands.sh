#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export ROSA_TOKEN AWS_ACCESS_KEY_ID AWS_DEFAULT_REGION AWS_SECRET_ACCESS_KEY AWS_SUBNET_IDS

AWS_DEFAULT_REGION=us-east-1

AWS_ACCESS_KEY_ID=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-access-key-id)
AWS_SECRET_ACCESS_KEY=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-secret-access-key)
AWS_SUBNET_IDS=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-subnet-ids)
ROSA_TOKEN=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/rosa-token)

cd "$(mktemp -d)"
curl -sSL https://raw.githubusercontent.com/konflux-ci/tekton-integration-catalog/main/scripts/rosa/delete-rosa-clusters.sh | bash
