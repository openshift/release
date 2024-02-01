#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function create_disk_encryption_set() {
    local rg=$1 kv_name=$2 kv_key_name=$3 des_name=$4 kv_id kv_key_url des_id kv_output kv_key_output des_output
    
    echo "Creating keyvault ${kv_name} in ${rg}"
    kv_output=$(mktemp)
    run_command "az keyvault create -n ${kv_name} -g ${rg} --enable-purge-protection true | tee '${kv_output}'" || return 1
    kv_key_output=$(mktemp)
    run_command "az keyvault key create --vault-name ${kv_name} -n ${kv_key_name} --protection software | tee '${kv_key_output}'" || return 1
    #sleep for a while to wait for azure api return correct id
    #sleep 60
    #kv_id=$(az keyvault show --name ${kv_name} --query "[id]" -o tsv) &&
    #kv_key_url=$(az keyvault key show --vault-name $kv_name --name $kv_key_name --query "[key.kid]" -o tsv) || return 1
    kv_id=$(jq -r '.id' "${kv_output}") &&
    kv_key_url=$(jq -r '.key.kid' "${kv_key_output}") || return 1
    
    echo "Creating disk encryption set for ${kv_name}"
    des_output=$(mktemp)
    run_command "az disk-encryption-set create -n ${des_name} -g ${rg} --source-vault ${kv_id} --key-url ${kv_key_url} | tee '${des_output}'" || return 1
    #des_id=$(az disk-encryption-set show -n ${des_name} -g ${rg} --query "[identity.principalId]" -o tsv) || return 1
    des_id=$(jq -r '.identity.principalId' "${des_output}") || return 1
    
    echo "Granting the DiskEncryptionSet resource access to the key vault"
    run_command "az keyvault set-policy -n ${kv_name} -g ${rg} --object-id ${des_id} --key-permissions wrapkey unwrapkey get" || return 1
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none


rg_file="${SHARED_DIR}/resourcegroup"
if [ -f "${rg_file}" ]; then
    RESOURCE_GROUP=$(cat "${rg_file}")
else
    echo "Did not found an provisoned empty resource group"
    exit 1
fi

run_command "az group show --name $RESOURCE_GROUP"; ret=$?
if [ X"$ret" != X"0" ]; then
    echo "The $RESOURCE_GROUP resrouce group does not exit"
    exit 1
fi

# create disk encryption set
# We must randomize the name of the keyvault as they do not get fully deleted for 90 days.
# A vault's name must be between 3-24 alphanumeric characters
cluster_sp_id=$(cat "${AZURE_AUTH_LOCATION}" | jq -r ".clientId")
azure_des_json="{}"
kv_prefix="${NAMESPACE#ci-op-}-${UNIQUE_HASH}"
if [[ "${ENABLE_DES_DEFAULT_MACHINE}" == "true" ]]; then
    echo "Creating keyvault and disk encryption set in ${RESOURCE_GROUP} for defaultMachinePlatform"
    keyvault_default="${kv_prefix}-kv-d"
    keyvault_key_default="${kv_prefix}-kvkey-d"
    des_default="${kv_prefix}-des-d"
    create_disk_encryption_set "${RESOURCE_GROUP}" "${keyvault_default}" "${keyvault_key_default}" "${des_default}"
    
    echo "Granting service principal reader permissions to the DiskEncryptionSet: ${des_default}"
    des_default_id=$(az disk-encryption-set show -n "${des_default}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    run_command "az role assignment create --assignee ${cluster_sp_id} --role Owner --scope ${des_default_id} -o jsonc"

    #save default des information to ${SHARED_DIR} for reference
    azure_des_json=$(echo "${azure_des_json}" | jq -c -S ". +={\"default\":\"${des_default}\"}")
fi

if [[ "${ENABLE_DES_CONTROL_PLANE}" == "true" ]]; then
    echo "Creating keyvault and disk encryption set in ${RESOURCE_GROUP} for ControlPlane"
    keyvault_master="${kv_prefix}-kv-m"
    keyvault_key_master="${kv_prefix}-kvkey-m"
    des_master="${kv_prefix}-des-m"
    create_disk_encryption_set "${RESOURCE_GROUP}" "${keyvault_master}" "${keyvault_key_master}" "${des_master}"

    echo "Granting service principal reader permissions to the DiskEncryptionSet: ${des_master}"
    des_master_id=$(az disk-encryption-set show -n "${des_master}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    run_command "az role assignment create --assignee ${cluster_sp_id} --role Owner --scope ${des_master_id} -o jsonc"

    #save control plane des information to ${SHARED_DIR} for reference
    azure_des_json=$(echo "${azure_des_json}" | jq -c -S ". +={\"master\":\"${des_master}\"}")
fi

if [[ "${ENABLE_DES_COMPUTE}" == "true" ]]; then
    echo "Creating keyvault and disk encryption set in ${RESOURCE_GROUP} for compute"
    keyvault_worker="${kv_prefix}-kv-w"
    keyvault_key_worker="${kv_prefix}-kvkey-w"
    des_worker="${kv_prefix}-des-w"
    create_disk_encryption_set "${RESOURCE_GROUP}" "${keyvault_worker}" "${keyvault_key_worker}" "${des_worker}"

    echo "Granting service principal reader permissions to the DiskEncryptionSet: ${des_worker}"
    des_worker_id=$(az disk-encryption-set show -n "${des_worker}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    run_command "az role assignment create --assignee ${cluster_sp_id} --role Owner --scope ${des_worker_id} -o jsonc"

    #save compute des information to ${SHARED_DIR} for reference
    azure_des_json=$(echo "${azure_des_json}" | jq -c -S ". +={\"worker\":\"${des_worker}\"}")
fi

# save disk encryption set information to ${SHARED_DIR} for reference
echo "${azure_des_json}" > "${SHARED_DIR}/azure_des.json"

#for debug
cat "${SHARED_DIR}/azure_des.json"
