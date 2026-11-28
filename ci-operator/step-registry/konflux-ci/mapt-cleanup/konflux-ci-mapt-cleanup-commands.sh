#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

AWS_ACCESS_KEY_ID=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-access-key-id)
AWS_SECRET_ACCESS_KEY=$(cat /usr/local/ci-secrets/konflux-devprod-rosa-credentials/aws-secret-access-key)
export AWS_REGION=us-east-1

cd "$(mktemp -d)"
curl -fsSL https://raw.githubusercontent.com/konflux-ci/tekton-integration-catalog/main/scripts/mapt/delete-mapt-clusters.sh | bash

# Install the IBM Cloud CLI and VPC plugin for this step only.
curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
ibmcloud config --check-version=false
ibmcloud plugin install -f vpc-infrastructure -v 17.1.0

export IBMCLOUD_API_KEY
IBMCLOUD_API_KEY=$(cat /usr/local/ci-secrets/ibmcloud-qe/ibmcloud-api-key)
curl -fsSL https://raw.githubusercontent.com/konflux-ci/tekton-integration-catalog/main/scripts/mapt/delete-mapt-ibmcloud-resources.sh | bash -s -- --sweep --age-hours 24
