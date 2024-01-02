#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

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
DES_NAME=$(< "${SHARED_DIR}/azure_des")

critical_check_result=0

#Get des id
des_id=$(az disk-encryption-set show -n "${DES_NAME}" -g "${DES_RESOURCE_GROUP}" --query '[id]' -otsv)

#check that node os disk is encrypted
nodes_list=$(oc get nodes --no-headers | awk '{print $1}')
for node in ${nodes_list}; do
    echo "--- check node ${node} ---"
    node_des_id=$(az vm show --name "${node}" -g "${CLUSTER_RESOURCE_GROUP}" --query 'storageProfile.osDisk.managedDisk.diskEncryptionSet.id' -otsv)
    if [[ "${node_des_id}" == "${des_id}" ]]; then
        echo "INFO: os disk for node ${node} is encrypted"
    else
        echo "ERROR: Get unexpected des id on os disk for node ${node}! expected value: ${des_id}, real value: ${node_des_id}"
        critical_check_result=1 
    fi
done

#check des setting in default sc
echo "--- check des setting in default sc ---"
if (( ocp_minor_version < 13 )) || [[ "${ENABLE_DES_DEFAULT_MACHINE}" != "true" ]]; then
    echo "DES setting in default sc is only available on 4.13+ and requires ENABLE_DES_DEFAULT_MACHINE set to true, no need to check on current cluster, skip."
else
    sc_des_id=$(oc get sc managed-csi -ojson | jq -r '.parameters.diskEncryptionSetID')
    if [[ "${des_id}" == "${sc_des_id}" ]]; then
        echo "default sc contains expected des setting!"
    else
        echo "ERROR: Fail to check des setting in default sc! expected des id: ${des_id}, sc des id: ${sc_des_id}"
        critical_check_result=1
    fi
fi
exit ${critical_check_result}
