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

check_result=0

cluster_identity_id=$(az identity list -g "${RESOURCE_GROUP}" --query "[].id" -otsv)
if [[ -z "${cluster_identity_id}" ]]; then
    echo "ERROR: could not find azure identity created by installer!"
    exit 1
fi
cluster_identity_principalId=$(az identity show --id ${cluster_identity_id} --query "principalId" -otsv)

echo -e "Azure identity created by installer:\nid: ${cluster_identity_id}\nprincipalId: ${cluster_identity_principalId}"
master_nodes_list=$(oc get nodes --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/master -o json | jq -r '.items[].metadata.name')
for node in ${master_nodes_list}; do
    node_identity_id=$(az vm show -g "${RESOURCE_GROUP}" -n "${node}" --query "identity.userAssignedIdentities.keys(@)" -otsv)
    node_identity_principalId=$(az vm show -g "${RESOURCE_GROUP}" -n "${node}" --query "identity.userAssignedIdentities.\"${node_identity_id}\".principalId" -otsv)
    echo "Checking on node ${node}..."
    if [[ "${cluster_identity_principalId}" == "${node_identity_principalId}" ]]; then
        echo "INFO: node ${node} attached the expected azure identity!"
    else
        echo "ERROR: unexpected azure identity attached on node ${node}, id: ${node_identity_id}; principalId: ${node_identity_principalId}"
        check_result=1
    fi
done

exit ${check_result}
