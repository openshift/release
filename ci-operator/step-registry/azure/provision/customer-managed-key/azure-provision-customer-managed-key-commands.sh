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

function run_command_with_retries()
{
    local try=0 cmd="$1" retries="${2:-}" ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}'"

    eval "${cmd}" || ret=$?
    while [ X"${ret}" != X"0" ] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success, waiting 60 sec....."
        sleep 60
        try=$((try + 1))
        ret=0
        eval "${cmd}" || ret=$?
    done
    if [ ${try} -eq ${max} ]; then
        echo "Never succeed or Timeout"
        return 1
    fi
    echo "Succeed"
    return 0
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
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
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

# create key
KV_BASE_NAME="${NAMESPACE}-${UNIQUE_HASH}"
keyvault_name="${KV_BASE_NAME}-kv"
key_name="${KV_BASE_NAME}-key"
user_assinged_identity_name="${KV_BASE_NAME}-identity"
# create keyvault
# set soft delete data retention to 7 days (minimum) instead of the default 90 days to reduce the risk of Key Vault name collisions
run_command "az keyvault create --name ${keyvault_name} --resource-group ${RESOURCE_GROUP} --enable-purge-protection --enable-rbac-authorization --retention-days 7"
kv_id=$(az keyvault show --resource-group ${RESOURCE_GROUP} --name ${keyvault_name} --query id --output tsv)
sp_id=$(az ad sp show --id ${AZURE_AUTH_CLIENT_ID} --query id -o tsv)
#assign role for sp on scope keyvault
run_command "az role assignment create --assignee ${sp_id} --role 'Key Vault Crypto Officer' --scope ${kv_id}"
#create key
run_command_with_retries "az keyvault key create --name ${key_name} --vault-name ${keyvault_name}" 5
#create user-assigned managed identity and assign role on scope keyvault
run_command "az identity create -g ${RESOURCE_GROUP} -n ${user_assinged_identity_name}"
identity_principal_id=$(az identity show -n ${user_assinged_identity_name} -g ${RESOURCE_GROUP} --query 'principalId' -otsv)
run_command "az role assignment create --assignee-object-id ${identity_principal_id} --role 'Key Vault Crypto Service Encryption User' --scope ${kv_id} --assignee-principal-type ServicePrincipal"

cat > "${SHARED_DIR}/customer_managed_key_for_installer_sa.yaml" <<EOF
platform:
  azure:
    customerManagedKey:
      keyVault:
        keyName: ${key_name}
        name: ${keyvault_name}
        resourceGroup: ${RESOURCE_GROUP}
      userAssignedIdentityKey: ${user_assinged_identity_name}
EOF
