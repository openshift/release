#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json

echo "Removing the identities from VMs ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")

AZ_SUB=$(jq -r '.subscriptionId' "${AZURE_AUTH_LOCATION}")
AZ_USERNAME=$(jq -r '.clientId' "${AZURE_AUTH_LOCATION}")
AZ_PASSWORD=$(jq -r '.clientSecret' "${AZURE_AUTH_LOCATION}")

az login --username "${AZ_USERNAME}" --password "${AZ_PASSWORD}"
az account set -s "${AZ_SUB}"

RESOURCE_GROUP="${INFRA_ID}-rg"

USER_ASSIGNED_IDENITITY_ID=$(az vm list -g ${RESOURCE_GROUP}  | jq -r '.[].id' | xargs -t az vm identity show --ids | jq -r '.[0].userAssignedIdentities | keys[0]')

az vm list -g "${RESOURCE_GROUP}"  | jq -r '.[].id' | xargs -t az vm identity remove --identities "${USER_ASSIGNED_IDENITITY_ID}" --ids

az vm list -g "${RESOURCE_GROUP}"  | jq -r '.[].id' | xargs -t az vm identity show --ids
