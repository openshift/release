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

function vm_urn_check() {

    local node_name=$1
    local node_urn=$2
    local rg_name=$3

    vm_urn=$(az vm get-instance-view -g ${rg_name} --name ${node_name} -ojson | jq -r '.storageProfile.imageReference | "\(.publisher):\(.offer):\(.sku):\(.version)"')
    if [[ "${vm_urn}" == "${node_urn}" ]]; then
        echo "urn check pass!"
        return 0
    else
        echo "urn check fail! expected urn: ${node_urn}, actual urn: ${vm_urn}"
        return 1
    fi
}

function vm_hyperv_generation_check() {

    local node_name=$1
    local node_generation=$2
    local rg_name=$3

    generation=$(az vm get-instance-view -g ${rg_name} --name ${node_name} --query 'instanceView.hyperVGeneration' -otsv)
    if [[ "${generation}" == "${node_generation}" ]]; then
        echo "generation check pass!"
        return 0
    else
        echo "generation check fail! expected generation: ${node_generation}, actual generation: ${generation}"
        return 1
    fi
}

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

if [[ ! -f "${SHARED_DIR}/azure_marketplace_image_urn_worker" ]]; then
    echo "Unable to find worker marketplace image config, exit!"
    exit 1
fi
worker_image_urn=$(< "${SHARED_DIR}/azure_marketplace_image_urn_worker")
worker_generation=$(az vm image show --urn ${worker_image_urn} --query hyperVGeneration -otsv)

critical_check_result=0

echo "---------- Check worker nodes urn and hyperV generation ----------"
worker_nodes_list=$(oc get nodes --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/worker -o json | jq -r '.items[].metadata.name')
for node in ${worker_nodes_list}; do
    echo "check worker node: ${node}"
    vm_urn_check "${node}" "${worker_image_urn,,}" "${RESOURCE_GROUP}" || critical_check_result=1
    vm_hyperv_generation_check "${node}" "${worker_generation}" "${RESOURCE_GROUP}" || critical_check_result=1
done

if [[ -f "${SHARED_DIR}/azure_marketplace_image_urn_master" ]]; then
    master_image_urn=$(< "${SHARED_DIR}/azure_marketplace_image_urn_master")
    master_generation=$(az vm image show --urn ${master_image_urn} --query hyperVGeneration -otsv)

    echo "---------- Check master nodes urn and hyperV generation ---------"
    master_nodes_list=$(oc get nodes --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/master -o json | jq -r '.items[].metadata.name')
    for node in ${master_nodes_list}; do
        echo "check master node: ${node}"
        vm_urn_check "${node}" "${master_image_urn,,}" "${RESOURCE_GROUP}" || critical_check_result=1
        vm_hyperv_generation_check "${node}" "${master_generation}" "${RESOURCE_GROUP}" || critical_check_result=1
    done
fi

exit ${critical_check_result}
