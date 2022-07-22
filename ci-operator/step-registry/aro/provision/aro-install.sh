#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing oc binary"
curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz | tar zxvf - oc
chmod +x oc

CLUSTER=mycluster
RESOURCEGROUP=myrg
VNET=$CLUSTER-VNET
LOCATION="centralus"
PULL_SECRET_FILE=/path/to/pull-PULL_SECRET_FILE

# get az-cli, do feature adds for cloud if needed
# 

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

CREATE_CMD="az aro create --resource-group ${RESOURCEGROUP} --name ${CLUSTER} --vnet ${VNET} --master-subnet master-subnet --worker-subnet worker-subnet"

