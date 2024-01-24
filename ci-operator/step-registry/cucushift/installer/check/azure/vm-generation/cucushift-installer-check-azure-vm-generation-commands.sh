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

function get_expected_generation() {
    local vm_type=$1

    if [[ -z "${vm_type}" ]] || [[ "${vm_type}" == "null" ]]; then
        #vm_type is empty, installer will use the default instance type which support both V1 and V2.
        echo "V2"
    else
        field_hyperv_gen=$(az vm list-skus --size ${vm_type} --location $REGION | jq -r '.[].capabilities[] | select(.name=="HyperVGenerations") | .value')

        case $field_hyperv_gen in
        "V1")
        echo "V1"
        ;;
        "V2" | "V1,V2")
        echo "V2"
        ;;
        *)
        echo "ERROR: unexpected HyperV Generation ${field_hyperv_gen} for instance type ${vm_type} in region ${REGION}!"
        return 1
        ;;
        esac
    fi

    return 0
}

function check_vm_generation() {
    local expected_vm_gen=$1
    local node_list=$2

    ret=0
    for node_name in ${node_list}; do
        echo "checking node ${node_name}"
        node_gen=$(az vm get-instance-view -g ${RESOURCE_GROUP} --name ${node_name} --query 'instanceView.hyperVGeneration' -otsv)
        if [[ "${node_gen}" == "${expected_vm_gen}" ]]; then
            echo "INFO: get expected vm generation!"
        else
            echo "ERROR: get unexpected vm generation, real generation is ${node_gen}!"
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
REGION=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.region')

master_vm_type=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.type')
worker_vm_type=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.type')

check_result=0
echo "Check vm generation on master nodes..."
master_expected_vm_gen=$(get_expected_generation "${master_vm_type}") || { echo ${master_expected_vm_gen}; exit 1; }
echo "master vm type: ${master_vm_type}, expected vm generation for master: ${master_expected_vm_gen}"
master_list=$(oc get node --no-headers | grep 'master' | awk '{print $1}')
check_vm_generation "${master_expected_vm_gen}" "${master_list}" || check_result=1

echo -e "\nCheck vm generation on worker nodes..."
worker_expected_vm_gen=$(get_expected_generation "${worker_vm_type}") || { echo ${worker_expected_vm_gen}; exit 1; }
echo "worker vm type: ${worker_vm_type}, expected vm generation for worker: ${worker_expected_vm_gen}"
worker_list=$(oc get node --no-headers | grep 'worker' | awk '{print $1}')
check_vm_generation "${worker_expected_vm_gen}" "${worker_list}" || check_result=1

exit ${check_result}
