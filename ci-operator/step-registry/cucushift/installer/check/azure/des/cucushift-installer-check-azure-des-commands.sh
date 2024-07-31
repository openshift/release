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
INFRA_ID=$(jq -r .infraID "${SHARED_DIR}"/metadata.json)
CLUSTER_RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${CLUSTER_RESOURCE_GROUP}" ]]; then
    CLUSTER_RESOURCE_GROUP="${INFRA_ID}-rg"
fi
DES_RESOURCE_GROUP=$(< "${SHARED_DIR}/resourcegroup")
AZURE_DES_FILE="${SHARED_DIR}/azure_des.json"

if [[ "${ENABLE_DES_DEFAULT_MACHINE}" == "true" ]]; then
    DES_DEFAULT=$(cat ${AZURE_DES_FILE} | jq -r '.default')
    DES_CONTROL_PLANE=${DES_DEFAULT}
    DES_COMPUTE=${DES_DEFAULT}
fi

if [[ "${ENABLE_DES_CONTROL_PLANE}" == "true" ]]; then
    DES_CONTROL_PLANE=$(cat ${AZURE_DES_FILE} | jq -r '.master')
fi

if [[ "${ENABLE_DES_COMPUTE}" == "true" ]]; then
    DES_COMPUTE=$(cat ${AZURE_DES_FILE} | jq -r '.worker')
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)

critical_check_result=0

#Get des id
expected_master_des_id=$(az disk-encryption-set show -n "${DES_CONTROL_PLANE}" -g "${DES_RESOURCE_GROUP}" --query '[id]' -otsv)
expected_worker_des_id=${expected_master_des_id}
if [[ "${DES_CONTROL_PLANE}" != "${DES_COMPUTE}" ]]; then
    expected_worker_des_id=$(az disk-encryption-set show -n "${DES_COMPUTE}" -g "${DES_RESOURCE_GROUP}" --query '[id]' -otsv)
fi

#check that master node os disk is encrypted
echo "Expected des on master node: ${DES_CONTROL_PLANE}"
master_nodes_list=$(oc get nodes --no-headers | grep "master" | awk '{print $1}')
for master_node in ${master_nodes_list}; do
    echo "--- check master node ${master_node} ---"
    master_node_des_id=$(az vm show --name "${master_node}" -g "${CLUSTER_RESOURCE_GROUP}" --query 'storageProfile.osDisk.managedDisk.diskEncryptionSet.id' -otsv)
    if [[ "${master_node_des_id}" == "${expected_master_des_id}" ]]; then
        echo "INFO: os disk for node ${master_node} is encrypted"
    else
        echo "ERROR: Get unexpected des id on os disk for node ${master_node}! expected value: ${expected_master_des_id}, real value: ${master_node_des_id}"
        critical_check_result=1 
    fi
done

#check that worker node os disk is encrypted
echo "Expected des on worker node: ${DES_COMPUTE}"
worker_nodes_list=$(oc get nodes --no-headers | grep "worker" | awk '{print $1}')
for worker_node in ${worker_nodes_list}; do
    echo "--- check worker node ${worker_node} ---"
    worker_node_des_id=$(az vm show --name "${worker_node}" -g "${CLUSTER_RESOURCE_GROUP}" --query 'storageProfile.osDisk.managedDisk.diskEncryptionSet.id' -otsv)
    if [[ "${worker_node_des_id}" == "${expected_worker_des_id}" ]]; then
        echo "INFO: os disk for node ${worker_node} is encrypted"
    else
        echo "ERROR: Get unexpected des id on os disk for node ${worker_node}! expected value: ${expected_worker_des_id}, real value: ${worker_node_des_id}"
        critical_check_result=1
    fi
done

# Check property encryptionAtHost is enabled on each node
encrypt_at_host_default=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.defaultMachinePlatform.encryptionAtHost')
encrypt_at_host_master=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.encryptionAtHost')
encrypt_at_host_master=${encrypt_at_host_master:-$encrypt_at_host_default}
encrypt_at_host_worker=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.encryptionAtHost')
encrypt_at_host_worker=${encrypt_at_host_worker:-$encrypt_at_host_default}
node_list=""
[[ "${encrypt_at_host_master}" == "true" ]] && node_list="${master_nodes_list}"
[[ "${encrypt_at_host_worker}" == "true" ]] && node_list="${node_list} ${worker_nodes_list}"

if [[ -n "${node_list}" ]]; then
    echo -e "\n********** Check property encryptionAtHost is enabled on each node **********"
    for node in ${node_list}; do
        status=$(az vm show -n "${node}" -g "${CLUSTER_RESOURCE_GROUP}" -ojson | jq -r  '.securityProfile.encryptionAtHost')
        if [[ "${status}" == "true" ]]; then
            echo "encryptionAtHost is set to true, check passed on node ${node}!"
        else
            echo "encryptionAtHost is set to ${status}, check failed on node ${node}!"
            critical_check_result=1
        fi
    done
fi

#check des setting in default sc
echo -e "\n--- check des setting in default sc ---"
if (( ocp_minor_version < 13 )) || [[ "${ENABLE_DES_DEFAULT_MACHINE}" != "true" ]]; then
    echo "DES setting in default sc is only available on 4.13+ and requires ENABLE_DES_DEFAULT_MACHINE set to true, no need to check on current cluster, skip."
else
    echo "Expected des in default sc: ${DES_DEFAULT}"
    expected_default_des_id=$(az disk-encryption-set show -n "${DES_DEFAULT}" -g "${DES_RESOURCE_GROUP}" --query '[id]' -otsv)
    sc_des_id=$(oc get sc managed-csi -ojson | jq -r '.parameters.diskEncryptionSetID')
    if [[ "${expected_default_des_id}" == "${sc_des_id}" ]]; then
        echo "default sc contains expected des setting!"
    else
        echo "ERROR: Fail to check des setting in default sc! expected des id: ${expected_default_des_id}, sc des id: ${sc_des_id}"
        critical_check_result=1
    fi
fi
exit ${critical_check_result}
