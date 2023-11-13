#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER=${CLUSTER:="${NAMESPACE}-${UNIQUE_HASH}"}
RESOURCEGROUP=${RESOURCEGROUP:=$(cat "${SHARED_DIR}/resourcegroup")}
VNET=${VNET:=$(cat "$SHARED_DIR/vnet")}
LOCATION=${LOCATION:=${LEASED_RESOURCE}}
PULL_SECRET_FILE=${PULL_SECRET_FILE:="${CLUSTER_PROFILE_DIR}/pull-secret"}
DISK_ENCRYPTION_SET_ENABLE=${DISK_ENCRYPTION_SET_ENABLE:=no}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
ARO_WORKER_COUNT=${ARO_WORKER_COUNT:=""}
ARO_MASTER_VM_SIZE=${ARO_MASTER_VM_SIZE:=""}
ARO_WORKER_VM_SIZE=${ARO_WORKER_VM_SIZE:=""}
ARO_CLUSTER_VERSION=${ARO_CLUSTER_VERSION:=""}

echo $CLUSTER > $SHARED_DIR/cluster-name
echo $LOCATION > $SHARED_DIR/location

echo "az-cli version information"
az version

echo "logging in with az using service principal"
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Creating required Azure objects (Network infrastructure)"

az provider register -n Microsoft.RedHatOpenShift --wait
az provider register -n Microsoft.Compute --wait
az provider register -n Microsoft.Storage --wait
az provider register -n Microsoft.Authorization --wait

CREATE_CMD="az aro create --resource-group ${RESOURCEGROUP} --name ${CLUSTER} --vnet ${VNET} --master-subnet master-subnet --worker-subnet worker-subnet "


if [ -f "$PULL_SECRET_FILE"  ]; then
    CREATE_CMD="$CREATE_CMD --pull-secret @\"$PULL_SECRET_FILE\" "
fi

# if azure_des file exists assume we want to use des for our aro cluster
if [ -f "${SHARED_DIR}/azure_des" ]; then
    des=$(cat ${SHARED_DIR}/azure_des)
    des_id=$(az disk-encryption-set show -n ${des} -g ${RESOURCEGROUP} --query "[id]" -o tsv)
    CREATE_CMD="${CREATE_CMD} --disk-encryption-set ${des_id} --master-encryption-at-host --worker-encryption-at-host "
fi

# Change master vm size from default
if [[ -n ${ARO_MASTER_VM_SIZE} ]]; then
    CREATE_CMD="${CREATE_CMD} --master-vm-size ${ARO_MASTER_VM_SIZE}"
fi

# Change worker vm size from default
if [[ -n ${ARO_WORKER_VM_SIZE} ]]; then
    CREATE_CMD="${CREATE_CMD} --worker-vm-size ${ARO_WORKER_VM_SIZE}"
fi

#change number of workers from default
if [[ -n ${ARO_WORKER_COUNT} ]]; then
    CREATE_CMD="${CREATE_CMD} --worker-count ${ARO_WORKER_COUNT}"
fi

#select an OCP version for ARO cluster
if [[ -n ${ARO_CLUSTER_VERSION} ]]; then
    echo "Will attempt to install ARO cluster using Openshift ${ARO_CLUSTER_VERSION}"
    echo "Available versions in ${LOCATION}:"
    az aro get-versions -l ${LOCATION} -o table
    CREATE_CMD="${CREATE_CMD} --version ${ARO_CLUSTER_VERSION}"
fi

echo "Running ARO create command:"
echo "${CREATE_CMD}"
eval "${CREATE_CMD}" > ${SHARED_DIR}/clusterinfo

echo "Cluster created, sleeping 600 seconds";
sleep 600

echo "Retrieving credentials"

KUBEAPI=$(cat ${SHARED_DIR}/clusterinfo | jq -r '.apiserverProfile.url')
KUBECRED=$(az aro list-credentials --name $CLUSTER --resource-group $RESOURCEGROUP)
KUBEUSER=$(echo "$KUBECRED" | jq -r '.kubeadminUsername')
KUBEPASS=$(echo "$KUBECRED" | jq -r '.kubeadminPassword')

echo "Logging into the cluster"

echo $KUBECRED > ${SHARED_DIR}/clustercreds

oc login "$KUBEAPI" --username="$KUBEUSER" --password="$KUBEPASS"

echo "Generating kubeconfig in ${SHARED_DIR}/kubeconfig"

oc config view --raw > ${SHARED_DIR}/kubeconfig

