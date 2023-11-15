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
    echo "Try to login..."
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function deleteDedicatedHost() {
    local dhName=$1 status
    dhg=$(${IBMCLOUD_CLI} is dh ${dhName} --output JSON | jq -r '.group.name')
    status=$(${IBMCLOUD_CLI} is dh ${dhName} --output JSON | jq -r ."lifecycle_state")

    if [[ "${status}" = "stable" ]]; then
        run_command "${IBMCLOUD_CLI} is dhu ${dhName} --enabled false"
    fi

    run_command "${IBMCLOUD_CLI} is dhd ${dhName} -f"
    run_command "${IBMCLOUD_CLI} is dhgd ${dhg} -f"
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

ibmcloud_login

#the file which saved the resource group of the pre created dedicated host group (just created when create the pre dedicated host, and not in Default group).
dhgRGFile=${SHARED_DIR}/ibmcloud_resource_group_dhg
dh_file=${SHARED_DIR}/dedicated_host

dhgRG=$(cat ${dhgRGFile})

run_command "ibmcloud target -g ${dhgRG}"

if [ -f ${dh_file} ]; then
    dhName=$(cat ${dh_file})
    echo "try to delete the dedicated host for master nodes and worker nodes ..."
    deleteDedicatedHost ${dhName}
fi

mapfile -t dhs < <(ibmcloud is dhs --resource-group-name ${dhgRG} -q | awk '(NR>1) {print $2}')
if [[ ${#dhs[@]} != 0 ]]; then
    echo "ERROR: fail to clean up the pre created dedicated host in ${dhgRG}:" "${dhs[@]}"
    exit 1
fi

delCmd="${IBMCLOUD_CLI} resource group-delete -f ${dhgRG}"
echo ${delCmd}
run_command_with_retries "${delCmd}" 20 20

