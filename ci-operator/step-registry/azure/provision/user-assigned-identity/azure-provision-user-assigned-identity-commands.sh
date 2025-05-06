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

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

rg_file="${SHARED_DIR}/resourcegroup"
if [ -f "${rg_file}" ]; then
    RESOURCE_GROUP=$(cat "${rg_file}")
else
    echo "Unable to find a provisoned empty resource group"
    exit 1
fi
identity_name_prefix="${NAMESPACE}-${UNIQUE_HASH}-identity"
azure_identity_json="{}"
# defalutMachinePlatform
if [[ "${ENABLE_AZURE_IDENTITY_DEFAULT_MACHINE}" == "true" ]]; then
    echo "Creating user-assigned identity to configure under defaultMachinePlatform..."
    azure_identity_json=$(echo "${azure_identity_json}" | jq -c -S ". +={\"identityDefault\":[]}")
    for num in $(seq 1 ${AZURE_USER_ASSIGNED_IDENTITY_NUMBER}); do
        identity_name="${identity_name_prefix}-default-${num}"
        run_command "az identity create -n \"${identity_name}\" -g ${RESOURCE_GROUP}"
        azure_identity_json=$(echo "${azure_identity_json}" | jq -c -S ".identityDefault += [{\"name\":\"${identity_name}\",\"subscription\":\"${AZURE_AUTH_SUBSCRIPTION_ID}\",\"resourceGroup\":\"${RESOURCE_GROUP}\"}]")
    done
fi
# ControlPlane
if [[ "${ENABLE_AZURE_IDENTITY_CONTROL_PLANE}" == "true" ]]; then
    echo "Creating user-assigned identity to configure under controlPlane..."
    azure_identity_json=$(echo "${azure_identity_json}" | jq -c -S ". +={\"identityControlPlane\":[]}")
    for num in $(seq 1 ${AZURE_USER_ASSIGNED_IDENTITY_NUMBER}); do
        identity_name="${identity_name_prefix}-contorlplane-${num}"
        run_command "az identity create -n \"${identity_name}\" -g ${RESOURCE_GROUP}"
        azure_identity_json=$(echo "${azure_identity_json}" | jq -c -S ".identityControlPlane += [{\"name\":\"${identity_name}\",\"subscription\":\"${AZURE_AUTH_SUBSCRIPTION_ID}\",\"resourceGroup\":\"${RESOURCE_GROUP}\"}]")
    done
fi
# Compute
if [[ "${ENABLE_AZURE_IDENTITY_COMPUTE}" == "true" ]]; then
    echo "Creating user-assigned identity to configure under compute..."
    azure_identity_json=$(echo "${azure_identity_json}" | jq -c -S ". +={\"identityCompute\":[]}")
    for num in $(seq 1 ${AZURE_USER_ASSIGNED_IDENTITY_NUMBER}); do
        identity_name="${identity_name_prefix}-compute-${num}"
        run_command "az identity create -n \"${identity_name}\" -g ${RESOURCE_GROUP}"
        azure_identity_json=$(echo "${azure_identity_json}" | jq -c -S ".identityCompute += [{\"name\":\"${identity_name}\",\"subscription\":\"${AZURE_AUTH_SUBSCRIPTION_ID}\",\"resourceGroup\":\"${RESOURCE_GROUP}\"}]")
    done
fi

# save user-assigned identity info to ${SHARED_DIR} for reference
echo "${azure_identity_json}" > "${SHARED_DIR}/azure_user_assigned_identity.json"
