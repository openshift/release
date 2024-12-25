#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function vars {
  source ${SHARED_DIR}/vars.sh
}

function verify {
    if [[ -z "${AZURE_SUBSCRIPTION_ID}" ]]; then
        echo ">> AZURE_SUBSCRIPTION_ID is not set"
        exit 1
    fi

    if [[ -z "${AZURE_LOCATION}" ]]; then
        echo ">> AZURE_LOCATION is not set"
        exit 1
    fi

    if [[ -z "${AZURE_CLUSTER_RESOURCE_GROUP}" ]]; then
        echo ">> AZURE_CLUSTER_RESOURCE_GROUP is not set"
        exit 1
    fi
}

function login {
  chmod +x ${SHARED_DIR}/azure-login.sh
  source ${SHARED_DIR}/azure-login.sh
}

function create-template {

  cat >> "bootstrap.bicep" << EOF
targetScope = 'resourceGroup'

param location string = resourceGroup().location

resource clusterVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'cluster-vnet'
  location: location
  properties: { addressSpace: { addressPrefixes: ['10.0.0.0/22'] } }
}

resource masterSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: 'master'
  parent: clusterVnet
  properties: { addressPrefixes: ['10.0.0.0/23'] }
}

resource workerSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: 'worker'
  parent: clusterVnet
  properties: { addressPrefixes: ['10.0.2.0/23'] }
}
EOF

}

function bootstrap {
  echo "Creating resource group ${AZURE_CLUSTER_RESOURCE_GROUP}"
  az group create \
      --subscription ${AZURE_SUBSCRIPTION_ID} \
      --resource-group ${AZURE_CLUSTER_RESOURCE_GROUP} \
      --location ${AZURE_LOCATION}

  echo "Creating cluster resources"
  az deployment group create \
      --subscription ${AZURE_SUBSCRIPTION_ID} \
      --resource-group ${AZURE_CLUSTER_RESOURCE_GROUP} \
      --name cluster-resources \
      --template-file ./bootstrap.bicep
}

# for saving files...
cd /tmp

vars
verify
login
create-template
bootstrap
