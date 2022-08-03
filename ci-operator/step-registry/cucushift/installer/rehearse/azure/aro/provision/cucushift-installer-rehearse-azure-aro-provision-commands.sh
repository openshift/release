#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#echo "Installing oc binary"
#curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz | tar zxvf - oc
#chmod +x oc

CLUSTER=${CLUSTER:="${NAMESPACE}-${JOB_NAME_HASH}"}
RESOURCEGROUP=${RESOURCEGROUP:="${NAMESPACE}-${JOB_NAME_HASH}-rg"}
VNET=${VNET:=${CLUSTER}-vnet}
LOCATION=${LOCATION:=${LEASED_RESOURCE}}
PULL_SECRET_FILE=${PULL_SECRET_FILE:=/path/to/pull_secret.txt}
DISK_ENCRYPTION_SET_ENABLE=${DISK_ENCRYPTION_SET_ENABLE:=no}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

echo $CLUSTER > $SHARED_DIR/cluster-name
echo $RESOURCEGROUP > $SHARED_DIR/resourcegroup
echo $LOCATION > $SHARED_DIR/location
echo $VNET > $SHARED_DIR/vnet

# get az-cli, do feature adds for cloud if needed
# 

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none


# see https://raw.githubusercontent.com/openshift/osde2e/main/ci/create-aro-cluster.sh
# create the resourcegroup to contain the cluster object and vnet
az group create \
    --name $RESOURCEGROUP \
    --location $LOCATION
    
az network vnet create \
    --resource-group $RESOURCEGROUP \
    --name $VNET \
    --address-prefixes 10.0.0.0/22

az network vnet subnet create \
    --resource-group $RESOURCEGROUP \
    --vnet-name $VNET \
    --name master-subnet \
    --address-prefixes 10.0.0.0/23 \
    --service-endpoints Microsoft.ContainerRegistry

az network vnet subnet create \
    --resource-group $RESOURCEGROUP \
    --vnet-name $VNET \
    --name worker-subnet \
    --address-prefixes 10.0.2.0/23 \
    --service-endpoints Microsoft.ContainerRegistry
    
az network vnet subnet update \
    --name master-subnet \
    --resource-group $RESOURCEGROUP \
    --vnet-name $VNET \
    --disable-private-link-service-network-policies true

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