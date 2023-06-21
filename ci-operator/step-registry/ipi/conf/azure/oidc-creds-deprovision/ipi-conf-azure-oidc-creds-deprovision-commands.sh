#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
REGION="${LEASED_RESOURCE}"

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
# jq is not available in the ci image...
#AZURE_AUTH_SUBSCRIPTION_ID="$(jq -r .subscriptionId ${AZURE_AUTH_LOCATION})"
AZURE_AUTH_SUBSCRIPTION_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep subscriptionId | cut -d ":" -f2)

# delete credentials infrastructure created by oidc-creds-provision configure step
ccoctl azure delete \
  --name="${CLUSTER_NAME}" \
  --region="${REGION}" \
  --subscription-id="${AZURE_AUTH_SUBSCRIPTION_ID}" \
  --delete-oidc-resource-group
