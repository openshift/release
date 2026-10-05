#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
#record the vpc info for OCP-60816 - [IPI-on-IBMCloud] install cluster under BYON with a different resource group.
# IBM Cloud CLI login
function ibmcloud_login {
  export IBMCLOUD_CLI=ibmcloud
  export IBMCLOUD_HOME=/output
  region="${LEASED_RESOURCE}"
  export region
  "${IBMCLOUD_CLI}" config --check-version=false
  echo "Try to login..."
  "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
  "${IBMCLOUD_CLI}" plugin list
}

function getResources() {
    "${IBMCLOUD_CLI}" resource service-instances --type all --output JSON | jq -r '.[]|.name+" "+.resource_id' | sort
}

#####################################
##############Initialize#############
#####################################
ibmcloud_login

resource_group=$(<"${SHARED_DIR}/ibmcloud_resource_group")

echo "Using region: ${region}  resource_group: ${resource_group}"
${IBMCLOUD_CLI} target -g ${resource_group}

#OCP-60816 - [IPI-on-IBMCloud] install cluster under BYON with a different resource group	
getResources > "${SHARED_DIR}/vpc_resources"