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

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function wait_for_co_healthy() {
    local timeout=300 interval=30 count=0
    while (( count < timeout )); do
        sleep ${interval}
        if ! unavailable_co=$(oc get co --no-headers| awk '{print $3$4$5}' | grep -v 'TrueFalseFalse'); then 
            return 0
        fi
        count=$(( count + interval ))
    done

    if (( count >= timeout )); then
        echo "WARN: some operators are not ready after waiting for ${timeout} seconds"
        echo >&2 "${unavailable_co}"
        return 1
    fi
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

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

master_lists=$(oc get nodes --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/master -o json | jq -r '.items[].metadata.name')
worker_lists=$(oc get nodes --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/worker -o json | jq -r '.items[].metadata.name')
node_lists="${master_lists} ${worker_lists}"

# Enable property encryptionAtHost on each node
for node in ${node_lists}; do
    echo -e "\n********** Enable encryptionAtHost on node $node **********"

    echo "mark node as unschedulable"
    run_command "oc adm cordon ${node}"

    if [[ "${worker_lists}" =~ ${node} ]]; then
        echo "drain worker node"
        run_command "oc adm drain ${node} --force=true --delete-emptydir-data --ignore-daemonsets"
    fi

    echo "de-allocate node"
    run_command "az vm deallocate -n ${node} -g ${RESOURCE_GROUP}"

    echo "set property encryptionAtHost to True on node"
    run_command "az vm update -n ${node} -g ${RESOURCE_GROUP} --set securityProfile.encryptionAtHost=true"

    echo "start node"
    run_command "az vm start -n ${node} -g ${RESOURCE_GROUP}"

    echo "wait for node get Ready"
    run_command "oc wait --for=condition=Ready node/${node} --timeout=180s"

    echo "mark node as schedulable"
    run_command "oc adm uncordon ${node}"

    echo "check all operators are avaiable"
    wait_for_co_healthy
done

# Check property encryptionAtHost is enabled on each node
check_result=0
echo -e "\n********** Check property diskEncryptionSet is enabled on each node **********"
for node in ${node_lists}; do
    status=$(az vm show -n "${node}" -g "${RESOURCE_GROUP}" -ojson | jq -r  '.securityProfile.encryptionAtHost')
    if [[ "${status}" == "true" ]]; then
        echo "encryptionAtHost is set to true, check passed on node ${node}!"
    else
        echo "encryptionAtHost is set to ${status}, check failed on node ${node}!"
        check_result=1
    fi
done

exit ${check_result}
