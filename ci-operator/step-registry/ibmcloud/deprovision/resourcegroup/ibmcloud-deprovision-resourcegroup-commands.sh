#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

rg_files="${SHARED_DIR}/ibmcloud_resource_group ${SHARED_DIR}/ibmcloud_cluster_resource_group"
for rg_file in ${rg_files}; do
    if [ -f "${rg_file}" ]; then
        resource_group=$(cat "${rg_file}")
        echo "Removing the resource group ${resource_group}"
        delCmd="${IBMCLOUD_CLI} resource group-delete -f ${resource_group}"
        run_command_with_retries "${delCmd}" 6 30 || true
    fi
done
