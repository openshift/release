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

function ssh_command() {
    local node_ip="$1"
    local cmd="$2"
    local ssh_options ssh_proxy_command bastion_ip bastion_ssh_user ssh_proxy_command=""

    ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
    if [[ -f "${SHARED_DIR}/bastion_public_address" ]]; then
        bastion_ip=$(<"${SHARED_DIR}/bastion_public_address")
        bastion_ssh_user=$(<"${SHARED_DIR}/bastion_ssh_user")
        ssh_proxy_command="-o ProxyCommand='ssh ${ssh_options} -W %h:%p ${bastion_ssh_user}@${bastion_ip}'"
    fi

    echo "ssh ${ssh_options} ${ssh_proxy_command} core@${node_ip} ${cmd}" | sh -
}

function get_networking_type() {
    local region=$1
    local type=$2

    ret_value=$(az vm list-skus --size ${type} --location ${region} | jq -r '.[].capabilities[] | select(.name=="AcceleratedNetworkingEnabled") | .value')
    if [[ "${ret_value}" == "True" ]]; then
        echo "Accelerated"
    else
        echo "Basic"
    fi
}

function vm_networking_type_check() {
    local node_info_list=$1
    local rg_name=$2
    local net_type=$3
    local nic_id accelated_networking_state expected_net_state ret_code=0

    if [[ "${net_type}" == "Accelerated" ]]; then
        expected_net_state="true"
    else
        expected_net_state="false"
    fi
    echo "Expected enableAcceleratedNetworking: ${expected_net_state}"

    for node_info in ${node_info_list}; do
        node_name=${node_info/:*}
        node_ip=${node_info#*:}
        echo "Checking on node ${node_name}, node ip is ${node_ip}..."
        nic_id=$(az vm get-instance-view --name ${node_name} -g ${rg_name} --query 'networkProfile.networkInterfaces[].id' -otsv | awk -F'/' '{print $NF}')
        accelated_networking_state=$(az network nic show --name ${nic_id} -g ${rg_name} --query 'enableAcceleratedNetworking')
        [[ -z "${accelated_networking_state}" ]] && accelated_networking_state=false

        if [[ "${accelated_networking_state}" == "${expected_net_state}" ]]; then
            echo "INFO: enableAcceleratedNetworking is as expected on node!"
        else
            echo "ERROR: get unexpected enableAcceleratedNetworking, real value is ${accelated_networking_state}!"
            ret_code=1
        fi

        if [[ "${accelated_networking_state}" == "true" ]]; then
            cmd="ethtool -S eth0 | grep vf_rx_packets | grep -v cpu | awk -F':' '{print \$2}'"
            packets=$(ssh_command "${node_ip}" "${cmd}")
            if [[ ${packets} -gt 0 ]]; then
                echo "INFO: check passed for the output of 'ethtool -S eth0'"
            else
                echo "ERROR: no traffic is flowing over VF interface from the output of 'ethtool -S eth0'!"
                ret_code=1
            fi
        fi
    done

    return ${ret_code}
}

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi
REGION=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.region')
MASTER_TYPE=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.type')
WORKER_TYPE=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.type')

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

expected_net_type_master=""
expected_net_type_worker=""
if [[ -n "${AZURE_DEFAULT_MACHINE_NETWORKING_TYPE}" ]]; then
    expected_net_type_master="${AZURE_DEFAULT_MACHINE_NETWORKING_TYPE}"
    expected_net_type_worker="${AZURE_DEFAULT_MACHINE_NETWORKING_TYPE}"
fi
if [[ -n "${AZURE_CONTROL_PLANE_NETWORKING_TYPE}" ]]; then
    expected_net_type_master="${AZURE_CONTROL_PLANE_NETWORKING_TYPE}"
fi
if [[ -n "${AZURE_COMPUTE_NETWORKING_TYPE}" ]]; then
    expected_net_type_worker="${AZURE_COMPUTE_NETWORKING_TYPE}"
fi

if [[ -z "${expected_net_type_master}" ]]; then
    if [[ -z "${MASTER_TYPE}" ]] || [[ "${MASTER_TYPE}" == "null" ]]; then
        expected_net_type_master="Accelerated"
    else
        expected_net_type_master=$(get_networking_type "${REGION}" "${MASTER_TYPE}")
    fi
fi

if [[ -z "${expected_net_type_worker}" ]]; then
    if [[ -z "${WORKER_TYPE}" ]] || [[ "${WORKER_TYPE}" == "null" ]]; then
        expected_net_type_worker="Accelerated"
    else
        expected_net_type_worker=$(get_networking_type "${REGION}" "${WORKER_TYPE}")
    fi
fi

check_result=0
master_info_list=$(oc get node -o wide --no-headers | grep 'master' | awk '{print $1":"$6}')
vm_networking_type_check "${master_info_list}" "${RESOURCE_GROUP}" "${expected_net_type_master}" || check_result=1

worker_info_list=$(oc get node -o wide --no-headers | grep 'worker' | awk '{print $1":"$6}')
vm_networking_type_check "${worker_info_list}" "${RESOURCE_GROUP}" "${expected_net_type_worker}" || check_result=1

exit ${check_result}
