#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
  local CMD="$1"
  echo "Running Command: ${CMD}"
  eval "${CMD}"
}

# IBM Cloud CLI login
function ibmcloud_login {
  export IBMCLOUD_CLI=ibmcloud
  export IBMCLOUD_HOME=/output
  region="${LEASED_RESOURCE}"
  export region
  "${IBMCLOUD_CLI}" config --check-version=false
  echo "Try to login..."
  "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function deleteBastion() {    
  local bastionFile name ip
  bastionFile="$1" rgName="$2"
  name=$(yq-go r "${bastionFile}" 'bastionHost')
  run_command "${IBMCLOUD_CLI} is instance-delete ${name} -f"
  ip=$(yq-go r "${bastionFile}" 'publicIpAddress')
  if [[ -n "${ip}" ]]; then
    run_command "${IBMCLOUD_CLI} is ips --resource-group-name ${rgName} | grep -w ${ip} | cut -d ' ' -f1 | xargs ${IBMCLOUD_CLI} is ipd -f"
  fi
}

ibmcloud_login


resource_group=$(cat "${SHARED_DIR}/ibmcloud_resource_group")
echo "Using region: ${region}  resource_group: ${resource_group}"

${IBMCLOUD_CLI} target -g ${resource_group}

bastion_info_yaml="${SHARED_DIR}/bastion-info.yaml"

echo "DEBUG" "Removing the bastion host based on ${bastion_info_yaml}"
cat ${bastion_info_yaml}
deleteBastion ${bastion_info_yaml} "${resource_group}"

