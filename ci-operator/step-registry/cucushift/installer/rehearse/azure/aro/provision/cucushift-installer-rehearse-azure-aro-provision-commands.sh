#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER=${CLUSTER:="${NAMESPACE}-${JOB_NAME_HASH}"}
RESOURCEGROUP=${RESOURCEGROUP:=$(cat "${SHARED_DIR}/resourcegroup")}
VNET=${VNET:=$(cat "$SHARED_DIR/vnet")}
LOCATION=${LOCATION:=${LEASED_RESOURCE}}
PULL_SECRET_FILE=${PULL_SECRET_FILE:=/path/to/pull_secret.txt}
DISK_ENCRYPTION_SET_ENABLE=${DISK_ENCRYPTION_SET_ENABLE:=no}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

echo $CLUSTER > $SHARED_DIR/cluster-name
echo $LOCATION > $SHARED_DIR/location

# get az-cli, do feature adds for cloud if needed
# 

# log in with az
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

if [ $DISK_ENCRYPTION_SET_ENABLE = "yes" ]; then
    DES_ID=$(cat $SHARED_DIR/desid)
    CREATE_CMD="$CREATE_CMD --disk-encryption-set \"$DES_ID\" --master-encryption-at-host --worker-encryption-at-host "
fi

echo "Running ARO create command"

AROINFO="$(eval "$CREATE_CMD")"

echo "Cluster created, sleeping 600";

sleep 600

echo "$AROINFO" > ${SHARED_DIR}/clusterinfo

echo "Retrieving credentials"

KUBEAPI=$(echo "$AROINFO" | jq -r '.apiserverProfile.url')
KUBECRED=$(az aro list-credentials --name $CLUSTER_NAME --resource-group $CLUSTER_NAME)
KUBEUSER=$(echo "$KUBECRED" | jq -r '.kubeadminUsername')
KUBEPASS=$(echo "$KUBECRED" | jq -r '.kubeadminPassword')

echo "Logging into the cluster"

echo $KUBECRED > ${SHARED_DIR}/clustercreds

oc login "$KUBEAPI" --username="$KUBEUSER" --password="$KUBEPASS"

echo "Generating kubeconfig in ${SHARED_DIR}/kubeconfig"

oc config view --raw > ${SHARED_DIR}/kubeconfig