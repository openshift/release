#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output
    region="${LEASED_RESOURCE}"
    rg=$1
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    echo "Try to login to ${rg}..."
    "${IBMCLOUD_CLI}" login -r ${region} -g ${rg} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function run_command_with_retries() {
  cmd="$1"
  retries="$2"
  interval="$3"

  if [ X"$retries" == X"" ]; then
      retries=20
  fi

  if [ X"$interval" == X"" ]; then
      interval=30
  fi

  set +o errexit
  output=$(eval "$cmd"); ret=$?
  try=1

  # avoid exit with "del Resource groups with active or pending reclamation instances can't be deleted"
  while [ X"$ret" != X"0" ] && [ $try -lt $retries ]; do
      sleep $interval
      output=$(eval "$cmd"); ret=$?
      try=$(expr $try + 1)
  done
  set -o errexit

  if [ X"$try" == X"$retries" ]; then
      return 2
  fi
  echo "$output"
  return 0
}

key_file="${SHARED_DIR}/ibmcloud_key.json"


cat ${key_file}
RESOURCE_GROUP=$(jq -r .resource_group ${key_file})
echo "ResourceGroup: ${RESOURCE_GROUP}"
ibmcloud_login ${RESOURCE_GROUP}

keyTypes=("master" "worker" "default")
for keyType in "${keyTypes[@]}"; do
    echo "delete the keys for ${keyType}..."
    keyInfo=$(jq -r .${keyType} ${key_file})
    echo $keyInfo
    if [[ -n "${keyInfo}" ]] && [[ "${keyInfo}" != "null" ]]; then
        id=$(echo $keyInfo | jq -r .id)
        keyid=$(echo $keyInfo | jq -r .keyID)
        run_command "ibmcloud kp key delete ${keyid} -i ${id} -f" || true
        run_command "ibmcloud resource service-instance-delete ${id} -f" || true
    fi
done

delCmd="${IBMCLOUD_CLI} resource group-delete -f ${RESOURCE_GROUP}"
echo ${delCmd}
run_command_with_retries "${delCmd}" 20 20



