#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
REGION="${LEASED_RESOURCE}"

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${ENABLE_MIN_PERMISSION_FOR_STS}" == "true" ]]; then
    if [[ -f "${SHARED_DIR}/azure_minimal_permission_sts" ]]; then
        echo "Setting AZURE credential with minimal permissions for ccoctl"
        AZURE_AUTH_LOCATION="${SHARED_DIR}/azure_minimal_permission_sts"
    else
        echo "ERROR: ENABLE_MIN_PERMISSION_FOR_STS is enabled, but the credential file \"azure_minimal_permission_sts\" is missing."
        echo "ERROR: Note, the credential file is created by step \"azure-provision-service-principal-minimal-permission\", please check."
        echo "Exit now."
        exit 1
    fi
fi

if [ ! -f "$AZURE_AUTH_LOCATION" ]; then
    echo "File not found: $AZURE_AUTH_LOCATION"
    exit 1
fi

# jq is not available in the ci image...
#AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId ${AZURE_AUTH_LOCATION})"
AZURE_SUBSCRIPTION_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep subscriptionId | cut -d ":" -f2)
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    echo "AZURE_SUBSCRIPTION_ID is empty"
    exit 1
fi

# AZURE_TENANT_ID="$(jq -r .tenantId ${AZURE_AUTH_LOCATION})"
AZURE_TENANT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep tenantId | cut -d ":" -f2)
export AZURE_TENANT_ID
if [ -z "$AZURE_TENANT_ID" ]; then
    echo "AZURE_TENANT_ID is empty"
    exit 1
fi

# AZURE_CLIENT_ID="$(jq -r .clientId ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep clientId | cut -d ":" -f2)
export AZURE_CLIENT_ID
if [ -z "$AZURE_CLIENT_ID" ]; then
    echo "AZURE_CLIENT_ID is empty"
    exit 1
fi

# AZURE_CLIENT_SECRET="$(jq -r .clientSecret ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_SECRET=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep clientSecret | cut -d ":" -f2)
export AZURE_CLIENT_SECRET
if [ -z "$AZURE_CLIENT_SECRET" ]; then
    echo "AZURE_CLIENT_SECRET is empty"
    exit 1
fi

# delete credentials infrastructure created by oidc-creds-provision configure step
ccoctl azure delete \
  --name="${CLUSTER_NAME}" \
  --region="${REGION}" \
  --subscription-id="${AZURE_SUBSCRIPTION_ID}" \
  --storage-account-name="$(tr -d '-' <<< ${CLUSTER_NAME})oidc" \
  --delete-oidc-resource-group
