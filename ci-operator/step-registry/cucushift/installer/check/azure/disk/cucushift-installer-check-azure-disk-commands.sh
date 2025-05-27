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

function check_disk_type() {
    local node_list=$1 rg_name=$2 expected_disk_type=$3 ret=0 node_name

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

function check_disk_size() { 
    local node_list=$1 rg_name=$2 expected_disk_size=$3 ret=0 node_name

    for node_name in ${node_list}; do
        echo "checking on node ${node_name}"
        node_disk_size=$(az disk show -n "${node_name}_OSDisk" -g "${rg_name}"  --query 'diskSizeGb' -otsv)
        if [[ "${node_disk_size}" == "${expected_disk_size}" ]]; then
            echo "INFO: get expected disk size!"
        else
            echo "ERROR: get unexpected disk size, real disk size is ${node_disk_size}!"
            ret=1
        fi
    done

    return $ret
}

function check_disk_cache() {
    local node_list=$1 rg_name=$2 expected_disk_cache=$3 ret=0 node

    for node in ${node_list}; do
        echo "checking on node ${node}"
        node_cache_type=$(az vm show -n ${node} -g ${rg_name} --query 'storageProfile.osDisk.caching' -otsv)
        if [[ "${node_cache_type}" == "${expected_disk_cache}" ]]; then
            echo "INFO: get expected os disk cache type!"
        else
            echo "ERROR: get unexpected os disk cache type - ${node_cache_type}!"
            ret=1
        fi
    done

    return ${ret}
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

# disk type check
echo "Check disk type on master nodes..."
echo "Expected disk type for master: ${expected_disk_type_master}"
master_list=$(oc get node --no-headers | grep 'master' | awk '{print $1}')
check_disk_type "${master_list}" "${RESOURCE_GROUP}" "${expected_disk_type_master}" || check_result=1

echo -e "\nCheck disk type on worker nodes..."
echo "Expected disk type for worker: ${expected_disk_type_worker}"
worker_list=$(oc get node --no-headers | grep 'worker' | awk '{print $1}')
check_disk_type "${worker_list}" "${RESOURCE_GROUP}" "${expected_disk_type_worker}" || check_result=1

# disk size check
expected_disk_size_master=""
expected_disk_size_worker=""
if [[ -n "${AZURE_DEFAULT_MACHINE_DISK_SIZE}" ]]; then
    expected_disk_size_master="${AZURE_DEFAULT_MACHINE_DISK_SIZE}"
    expected_disk_size_worker="${AZURE_DEFAULT_MACHINE_DISK_SIZE}"
fi
if [[ -n "${AZURE_CONTROL_PLANE_DISK_SIZE}" ]]; then
    expected_disk_size_master="${AZURE_CONTROL_PLANE_DISK_SIZE}"
fi
if [[ -n "${AZURE_COMPUTE_DISK_SIZE}" ]]; then
    expected_disk_size_worker="${AZURE_COMPUTE_DISK_SIZE}"
fi  

if [[ -n "${expected_disk_size_master}" ]]; then
    echo "Check disk size on master nodes..."
    echo "Expected disk size for master: ${expected_disk_size_master}"
    check_disk_size "${master_list}" "${RESOURCE_GROUP}" "${expected_disk_size_master}" || check_result=1
else
    echo "INFO: skip checking disk size on master node as not customizing in install-config."
fi

if [[ -n "${expected_disk_size_worker}" ]]; then
    echo -e "\nCheck disk size on worker nodes..."
    echo "Expected disk size for worker: ${expected_disk_size_worker}"
    check_disk_size "${worker_list}" "${RESOURCE_GROUP}" "${expected_disk_size_worker}" || check_result=1
else
    echo "INFO: skip checking disk size on worker node as not customizing in install-config."
fi

# os disk cache check
# will remove the version check when OCPBUGS-33470 backport to old version
ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if (( ${ocp_minor_version} < 16 )); then
    echo "Disk cache checking is available on 4.16+ cluster currently, skip the check!"
    exit ${check_result}
fi

expected_cache_type="ReadWrite"
echo -e "\nCheck os disk catch type on all nodes..."
echo "Expected disk cache type: ${expected_cache_type}"
node_list="${master_list} ${worker_list}"
check_disk_cache "${node_list}" "${RESOURCE_GROUP}" "${expected_cache_type}" || check_result=1

exit ${check_result}
