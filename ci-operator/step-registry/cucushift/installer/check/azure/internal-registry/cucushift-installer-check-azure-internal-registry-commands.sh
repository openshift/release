#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

function field_check() {

    local expected_value=$1 actual_value=$2

    #shellcheck disable=SC2076
    if [[ "${expected_value}" == "${actual_value}" ]] || [[ " ${expected_value} " =~ " ${actual_value} " ]]; then
        echo "Get expected value!"
        return 0
    else
        echo "ERROR: Get unexpected value! expected value: ${expected_value}; actual value: ${actual_value}"
        return 1
    fi
}

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

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
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

vnet_resource_group=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.networkResourceGroupName')
vnet_name=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.virtualNetwork')
master_subnet=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.controlPlaneSubnet')
worker_subnet=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.computeSubnet')
vnet_subnet_name="${worker_subnet} or ${master_subnet}"
if [[ -z "${vnet_resource_group}" ]]; then
    vnet_name="${INFRA_ID}-vnet"
    vnet_subnet_name="${INFRA_ID}-master-subnet or ${INFRA_ID}-worker-subnet"
fi
image_registry_sa_name=$(az storage account list -g ${RESOURCE_GROUP} --query '[].name' -otsv | grep imageregistry)
image_registry_private_endpoint=$(az network private-endpoint list -g ${RESOURCE_GROUP} --query '[].name' -otsv)

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ret=0 
image_registry_spec_file=$(mktemp)
oc get config.image/cluster -ojson | jq -r '.spec.storage.azure' | tee -a ${image_registry_spec_file}

echo "Check spec of image-registry config have correct setting..."
echo "storage account name check..."
sa_name_registry_in_cluster="$(jq -r '.accountName' ${image_registry_spec_file})"
#shellcheck disable=SC2076
if [[ " ${image_registry_sa_name} " =~ " ${sa_name_registry_in_cluster} " ]]; then
    echo "Get expected value!"
else
    echo "ERROR: Get unexpected value! expected value: ${image_registry_sa_name}; actual value: ${sa_name_registry_in_cluster}"
    ret=1
fi
if [[ -n "${vnet_resource_group}" ]]; then
    echo "networkResourceGroupName check..."
    field_check "${vnet_resource_group}" "$(jq -r '.networkAccess.internal.networkResourceGroupName' ${image_registry_spec_file})" || ret=1
fi
echo "privateEndpointName check..."
field_check "${image_registry_private_endpoint}" "$(jq -r '.networkAccess.internal.privateEndpointName' ${image_registry_spec_file})" || ret=1
echo "subnetName check..."
field_check "${vnet_subnet_name}" "$(jq -r '.networkAccess.internal.subnetName' ${image_registry_spec_file})" || ret=1
echo "vnetName check..."
field_check "${vnet_name}" "$(jq -r '.networkAccess.internal.vnetName' ${image_registry_spec_file})" || ret=1
echo "type check..."
field_check "Internal" "$(jq -r '.networkAccess.type' ${image_registry_spec_file})" || ret=1

exit $ret
