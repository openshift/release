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

    if [[ -z "${AZURE_CLUSTER_RESOURCE_GROUP}" ]]; then
        echo ">> AZURE_CLUSTER_RESOURCE_GROUP is not set"
        exit 1
    fi
}

function login {
  chmod +x ${SHARED_DIR}/azure-login.sh
  source ${SHARED_DIR}/azure-login.sh
}

function clean {
  echo "Deleting cluster resource group"
  az group delete --yes \
      --subscription ${AZURE_SUBSCRIPTION_ID} \
      --resource-group ${AZURE_CLUSTER_RESOURCE_GROUP}
}

vars
verify
login
clean
