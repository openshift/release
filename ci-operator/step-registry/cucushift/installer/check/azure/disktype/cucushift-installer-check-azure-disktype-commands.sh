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

function check_disk_type() {
    local node_list=$1
    local rg_name=$2
    local expected_disk_type=$3

    ret=0
    for node_name in ${node_list}; do
        echo "checking on node ${node_name}"
        node_disk_type=$(az disk show -n "${node_name}_OSDisk" -g "${rg_name}"  --query 'sku.name' -otsv)
        if [[ "${node_disk_type}" == "${expected_disk_type}" ]]; then
            echo "INFO: get expected disk type!"
        else
            echo "ERROR: get unexpected disk type, real disk type is ${node_disk_type}!"
            ret=1
        fi
    done

    return $ret
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

expected_disk_type_master="Premium_LRS"
expected_disk_type_worker="Premium_LRS"
if [[ -n "${AZURE_DEFAULT_MACHINE_DISK_TYPE}" ]]; then
    expected_disk_type_master="${AZURE_DEFAULT_MACHINE_DISK_TYPE}"
    expected_disk_type_worker="${AZURE_DEFAULT_MACHINE_DISK_TYPE}"
fi
if [[ -n "${AZURE_CONTROL_PLANE_DISK_TYPE}" ]]; then
    expected_disk_type_master="${AZURE_CONTROL_PLANE_DISK_TYPE}"
fi
if [[ -n "${AZURE_COMPUTE_DISK_TYPE}" ]]; then
    expected_disk_type_worker="${AZURE_COMPUTE_DISK_TYPE}"
fi

check_result=0
echo "Check disk type on master nodes..."
echo "Expected disk type for master: ${expected_disk_type_master}"
master_list=$(oc get node --no-headers | grep 'master' | awk '{print $1}')
check_disk_type "${master_list}" "${RESOURCE_GROUP}" "${expected_disk_type_master}" || check_result=1

echo -e "\nCheck disk type on worker nodes..."
echo "Expected disk type for worker: ${expected_disk_type_worker}"
worker_list=$(oc get node --no-headers | grep 'worker' | awk '{print $1}')
check_disk_type "${worker_list}" "${RESOURCE_GROUP}" "${expected_disk_type_worker}" || check_result=1

exit ${check_result}
