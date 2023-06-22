#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
REGION="${LEASED_RESOURCE}"

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
# jq is not available in the ci image...
#AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId ${AZURE_AUTH_LOCATION})"
AZURE_SUBSCRIPTION_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep subscriptionId | cut -d ":" -f2)
# AZURE_TENANT_ID="$(jq -r .tenantId ${AZURE_AUTH_LOCATION})"
AZURE_TENANT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep tenantId | cut -d ":" -f2)
export AZURE_TENANT_ID
# AZURE_CLIENT_ID="$(jq -r .clientId ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep clientId | cut -d ":" -f2)
export AZURE_CLIENT_ID
# AZURE_CLIENT_SECRET="$(jq -r .clientSecret ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_SECRET=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep clientSecret | cut -d ":" -f2)
export AZURE_CLIENT_SECRET

# delete credentials infrastructure created by oidc-creds-provision configure step
ccoctl azure delete \
  --name="${CLUSTER_NAME}" \
  --region="${REGION}" \
  --subscription-id="${AZURE_SUBSCRIPTION_ID}" \
  --delete-oidc-resource-group
