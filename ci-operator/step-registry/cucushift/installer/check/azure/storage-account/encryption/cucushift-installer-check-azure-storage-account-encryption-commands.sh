#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
CLUSTER_RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${CLUSTER_RESOURCE_GROUP}" ]]; then
    CLUSTER_RESOURCE_GROUP="${INFRA_ID}-rg"
fi

if [ -f "${SHARED_DIR}/customer_managed_key_for_installer_sa.yaml" ]; then
    cmk_sa_file="${SHARED_DIR}/customer_managed_key_for_installer_sa.yaml"
    kv_rg=$(yq-go r "${cmk_sa_file}" "platform.azure.customerManagedKey.keyVault.resourceGroup")
    kv_name=$(yq-go r "${cmk_sa_file}" "platform.azure.customerManagedKey.keyVault.name")
    kv_key_name=$(yq-go r "${cmk_sa_file}" "platform.azure.customerManagedKey.keyVault.keyName")
    user_assigned_identity=$(yq-go r "${cmk_sa_file}" "platform.azure.customerManagedKey.userAssignedIdentityKey")
else
    echo "ERROR: could not find customer_managed_key_for_installer_sa.yaml in SHARED_DIR, exit!"
    exit 1
fi

critical_check_result=0
kv_uri=$(az keyvault show --resource-group ${kv_rg} --name ${kv_name} --query 'properties.vaultUri' -otsv)
key_kid=$(az keyvault key show --name ${kv_key_name} --vault-name ${kv_name} --query 'key.kid' -otsv)
user_assigned_identity_id=$(az identity show -g ${kv_rg} -n ${user_assigned_identity} --query "id" -otsv)

#query encryption on storage account
sa_name=$(az storage account list -g ${CLUSTER_RESOURCE_GROUP} --query '[].name' -otsv | grep "cluster")
sa_blob_public_access=$(az storage account show -n ${sa_name} -g ${CLUSTER_RESOURCE_GROUP} --query 'allowBlobPublicAccess' -otsv)
sa_kv_uri=$(az storage account show -n ${sa_name} -g ${CLUSTER_RESOURCE_GROUP} --query 'encryption.keyVaultProperties.keyVaultUri' -otsv)
sa_key_kid=$(az storage account show -n ${sa_name} -g ${CLUSTER_RESOURCE_GROUP} --query 'encryption.keyVaultProperties.currentVersionedKeyIdentifier' -otsv)
sa_keyname=$(az storage account show -n ${sa_name} -g ${CLUSTER_RESOURCE_GROUP} --query 'encryption.keyVaultProperties.keyName' -otsv)
sa_user_assigned_identity=$(az storage account show -n ${sa_name} -g ${CLUSTER_RESOURCE_GROUP} --query 'encryption.encryptionIdentity.encryptionUserAssignedIdentity' -otsv)

echo "Encryption content on storage account ${sa_name}"
az storage account show -n ${sa_name} -g ${CLUSTER_RESOURCE_GROUP}

echo -e "\ncustomer managed key created by user:"
echo -e "keyvault name: ${kv_name}\nkeyvault Uri: ${kv_uri}\nkey identity: ${key_kid}\nuser assigned identity id: ${user_assigned_identity_id}\n"
echo "check storage blob public access..."
if [[ "${sa_blob_public_access}" != "true" ]]; then
    echo "ERROR: required allowBlobPublicAccess should be true, but get value: ${sa_blob_public_access}!"
    critical_check_result=1
fi

echo "check key name on storage account..."
if [[ "${sa_keyname}" != "${kv_key_name}" ]]; then
    echo "ERROR: expected key name is ${kv_key_name}, but get value: ${sa_keyname}!"
    critical_check_result=1
fi

echo "check key id on storage account..."
if [[ "${sa_key_kid}" != "${key_kid}" ]]; then
    echo "ERROR: expected id is ${key_kid}, but get value: ${sa_key_kid}!"
    critical_check_result=1
fi

echo "check key vault Uri on storage account..."
if [[ "${sa_kv_uri}" != "${kv_uri}" ]]; then
    echo "ERROR: expected key vault Uri is ${kv_uri}, but get value: ${sa_kv_uri}!"
    critical_check_result=1
fi

echo "check user assinged identity on storage account..."
sa_user_assigned_identity=$(echo ${sa_user_assigned_identity} | awk '{print tolower($0)}')
user_assigned_identity_id=$(echo ${user_assigned_identity_id} | awk '{print tolower($0)}')
if [[ "${sa_user_assigned_identity}" != "${user_assigned_identity_id}" ]]; then
    echo "ERROR: expected user assigned identity is ${user_assigned_identity_id}, but get value: ${sa_user_assigned_identity}!"
    critical_check_result=1
fi

exit ${critical_check_result}
