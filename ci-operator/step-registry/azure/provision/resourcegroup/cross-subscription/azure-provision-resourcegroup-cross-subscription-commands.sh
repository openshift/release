#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

RG_NAME="${NAMESPACE}-${UNIQUE_HASH}-rg-cross-sub"
REGION="${HYPERSHIFT_AZURE_LOCATION:-${LEASED_RESOURCE}}"
echo "Azure region: ${REGION}"

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
if [[ -f "${SHARED_DIR}/azure-sp-contributor.json" ]]; then
  echo "Setting AZURE credential with Contributor role only for installer"
  AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/azure-sp-contributor.json" 
else
  echo "The credential for specific service principal doesn't exist, exit!"
  exit 1
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
#AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
# the crossSubscription ("Openshift QE 1") is saved in azure-sp-contributor.json 
CROSS_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .crossSubscriptionId)"
echo "${CROSS_SUBSCRIPTION_ID}" > "${SHARED_DIR}/cross_subscription_id" 

# log in with az
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${CROSS_SUBSCRIPTION_ID}

# create an empty resource group
az group create -l "${REGION}" -n "${RG_NAME}"

# save resource group information to ${SHARED_DIR} for reference and deprovision step
echo "${RG_NAME}" > "${SHARED_DIR}/resourcegroup_cross-sub"

# Grant the Contributor role to service principal on the resource group in cross subscription 
#az role assignment create \
#  --role "Contributor" \
#  --assignee "${AZURE_AUTH_CLIENT_ID}" \
#  --scope /subscriptions/"${CROSS_SUBSCRIPTION_ID}"/resourceGroups/"${RG_NAME}"  
