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
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

no_critical_check_result=0

echo "Checking if storage account is publicly accessible in ${RESOURCE_GROUP}"

sa_access_output=$(mktemp)
az storage account list -g ${RESOURCE_GROUP} --query "[].[name,allowBlobPublicAccess]" -o tsv 1>${sa_access_output} || no_critical_check_result=1
if [[ ${no_critical_check_result=} == 1 ]]; then
    echo "ERROR: fail to list storage account on cluster ${INFRA_ID}!"
    [[ "${EXIT_ON_INSTALLER_CHECK_FAIL}" == "yes" ]] && exit 1
    exit 0
fi

cat "${sa_access_output}" | while read line || [[ -n $line ]]; 
do
    name=$(echo $line | awk -F' ' '{print $1}')
    access=$(echo $line | awk -F' ' '{print $2}')
    if [[ "${access}" == "False" ]]; then
        echo "storage account ${name} property allowBlobPublicAccess is False, which is expected!"
    else
        echo "storage account ${name} property allowBlobPublicAccess is ${access}, which is not expected!"
        no_critical_check_result=1
    fi
done

if [[ ${no_critical_check_result} == 1 ]]; then
    echo "storage account public access check failed!"
    [[ "${EXIT_ON_INSTALLER_CHECK_FAIL}" == "yes" ]] && exit 1
fi 

exit 0
