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
REGION=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.region')

no_critical_check_result=0
# Get master/worker instance type
master_instance_type=$(oc get machine --selector machine.openshift.io/cluster-api-machine-type=master -n openshift-machine-api -ojson | jq -r '.items[].spec.providerSpec.value.vmSize' | sort -u)
worker_instance_type=$(oc get machine --selector machine.openshift.io/cluster-api-machine-type=worker -n openshift-machine-api -ojson | jq -r '.items[].spec.providerSpec.value.vmSize' | sort -u)

# Check on master nodes, each VM should be provisioned across zones
master_zones=$(az vm list-skus -l ${REGION} --zone --size ${master_instance_type} --query '[].locationInfo[].zones' -otsv)
if [[ "${master_zones}" == "" ]]; then
    echo "WARN: vm size ${master_instance_type} in region ${REGION} does not support zone, skip check on master node."
else
    echo "------ Check master nodes provisioned across zone ------"
    for zone in ${master_zones}; do
        master_node_name=$(oc get machine -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=master,machine.openshift.io/zone=${zone} -ojson | jq -r '.items[].metadata.name')
        if [[ -z "${master_node_name}" ]]; then
            echo "ERROR: not found master node in zone ${zone}"
            no_critical_check_result=1
        else
            echo "INFO: master node ${master_node_name} is in zone ${zone}"
        fi
   done
fi

worker_zones=$(az vm list-skus -l ${REGION} --zone --size ${worker_instance_type} --query '[].locationInfo[].zones' -otsv)
if [[ "${worker_zones}" == "" ]]; then
    echo "WARN: vm size ${worker_instance_type} in region ${REGION} does not support zone, skip check on worker node."
else
    echo "------ Check worker nodes provisioned across zone ------"
    for zone in ${worker_zones}; do
        worker_node_name=$(oc get machine -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=worker,machine.openshift.io/zone=${zone} -ojson | jq -r '.items[].metadata.name')
        if [[ -z "${worker_node_name}" ]]; then
            echo "ERROR: not found worker node in zone ${zone}"
            no_critical_check_result=1
        else
            echo "INFO: worker node ${worker_node_name} is in zone ${zone}"
        fi
   done
fi

if [[ ${no_critical_check_result} == 1 ]]; then
    echo "ERROR: nodes provisoned across zones check failed!"
    [[ "${EXIT_ON_INSTALLER_CHECK_FAIL}" == "yes" ]] && exit 1
fi

exit 0
