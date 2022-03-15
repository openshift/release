#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

RG_NAME="${NAMESPACE}-${JOB_NAME_HASH}-rg"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

# create an empty resource group
az group create -l "${REGION}" -n "${RG_NAME}"

# save resource group information to ${SHARED_DIR} for reference and deprovision step
echo "${RG_NAME}" > "${SHARED_DIR}/resouregroup"
