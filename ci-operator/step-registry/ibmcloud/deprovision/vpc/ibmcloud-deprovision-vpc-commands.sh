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


function check_vpc() {
  local vpcName="$1" vpc_info_file="$2"

  "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON > "${vpc_info_file}" || return 1
}

function check_public_gateway() {
  local rgName="$1" public_gateway_info_file="$2"

  run_command "${IBMCLOUD_CLI} is public-gateways --resource-group-name ${rgName} --output JSON > ${public_gateway_info_file}" || return 1
}

function delete_vpc() {
  local vpc_name="$1"
  local vpc_info_file public_gateway_info subnet gateway

  vpc_info_file="${ARTIFACT_DIR}/vpc_info"
  check_vpc "${vpc_name}" "${vpc_info_file}"

  for subnet in $(cat "${vpc_info_file}" | jq -r ".subnets[] | .name"); do
      run_command "${IBMCLOUD_CLI} is subnetd -f ${subnet}"
  done

  public_gateway_info="${ARTIFACT_DIR}/public_gateway_info"
  check_public_gateway "${resource_group}" "${public_gateway_info}"
  for gateway in $(cat "${public_gateway_info}" | jq -r --arg z "${vpc_name}" '.[] | select(.vpc.name==$z) | .name'); do
      run_command "${IBMCLOUD_CLI} is pubgwd -f ${gateway}"
  done

  sleep 15
  run_command "${IBMCLOUD_CLI} is vpcd -f ${vpc_name}"
}

ibmcloud_login

vpc_name=$(cat "${SHARED_DIR}/ibmcloud_vpc_name")

resource_group=$(cat "${SHARED_DIR}/ibmcloud_resource_group")
echo "Using region: ${region}  resource_group: ${resource_group} vpc: ${vpc_name}"

"${IBMCLOUD_CLI}" target -g ${resource_group}

echo "DEBUG" "Removing the vpc ${vpc_name} ..."
delete_vpc "${vpc_name}"

echo "DEBUG" "Removing the resource reclamations ..."
if [[ $("${IBMCLOUD_CLI}" resource reclamations -q) == "No reclamation found" ]]; then
  echo "No reclamation found"
else
  ${IBMCLOUD_CLI} resource reclamations -q |  awk '(NR>1) {print $1}' | xargs -n1 ibmcloud resource reclamation-delete -f
fi

echo "DEBUG" "Removing the resource group ${resource_group}"
delCmd="${IBMCLOUD_CLI} resource group-delete -f ${resource_group}"
run_command_with_retries "${delCmd}" 20 20