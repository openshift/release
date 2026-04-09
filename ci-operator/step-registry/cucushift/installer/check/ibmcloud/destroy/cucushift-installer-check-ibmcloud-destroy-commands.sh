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


function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

ibmcloud_login

CLUSTER_FILTER="${NAMESPACE}-${UNIQUE_HASH}"
hasError=0
set +e
resource_group=$(${IBMCLOUD_CLI} resource groups | awk '(NR>3) {print $1}' | grep ${CLUSTER_FILTER})
set -e
echo "Resource group: $resource_group"

if [ ! -z ${resource_group} ]; then
    "${IBMCLOUD_CLI}" target -g ${resource_group}

    echo "DEBUG" "Checking the remaining resources and the last_operation of the resources in ${resource_group}..."
    count=$(eval "${IBMCLOUD_CLI}" resource service-instances --type all -g ${resource_group} --output JSON | jq '.[]|.name' | wc -l)
    if [ "${count}" -gt 0 ]; then
        echo "ERROR: has remaining resource ..."
        "${IBMCLOUD_CLI}" resource service-instances --type all -g ${resource_group} --output JSON | jq '.[]|.name+" | "+.resource_id+" | "+.crn + " | " +(.last_operation|tostring)'
        hasError=1
    fi
fi

echo "DEBUG" "Checking the remaining dns resource-records ..."
if [ -f "${CLUSTER_PROFILE_DIR}/ibmcloud-cis" ]; then
  ibmcloud_cis_instance_name="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cis")"
else
  ibmcloud_cis_instance_name="Openshift-IPI-CI-CIS"
  ${IBMCLOUD_CLI} dns instances
fi
echo "IBMCLOUD_DNS_INSTANCE_NAME: $IBMCLOUD_DNS_INSTANCE_NAME, BASE_DOMAIN: $BASE_DOMAIN"
if [ ! -z ${IBMCLOUD_DNS_INSTANCE_NAME} ] && [ ! -z ${BASE_DOMAIN} ]; then
  cmd="${IBMCLOUD_CLI} dns zones -i ${IBMCLOUD_DNS_INSTANCE_NAME} -o json | jq -r --arg n ${BASE_DOMAIN} '.[] | select(.name==\$n) | .id'"
  dns_zone_id=$(eval "${cmd}")
  if [[ -z "${dns_zone_id}" ]]; then
    echo "Debug: Did not find dns_zone_id per the output of '${cmd}'"
  else
    set +e
    cmd="${IBMCLOUD_CLI} dns resource-records ${dns_zone_id} -i ${IBMCLOUD_DNS_INSTANCE_NAME} | grep -w ${CLUSTER_FILTER}"
    count=$(eval "${cmd} -c")
    set -e
    if [ "${count}" -gt 0 ]; then
      echo "ERROR: remaining dns resource-records..."
      run_command "${cmd}"
      hasError=1
    fi
  fi
fi

echo "DEBUG" "Checking the remaining cis dns-records on ${ibmcloud_cis_instance_name}..."
if [ ! -z ${BASE_DOMAIN} ] && [ ! -z ${ibmcloud_cis_instance_name} ]; then
  cmd="${IBMCLOUD_CLI} cis domains -i ${ibmcloud_cis_instance_name} -o json | jq -r --arg n ${BASE_DOMAIN} '.[] | select(.name==\$n) | .id'"
  domain_id=$(eval "${cmd}")
  if [[ -z "${domain_id}" ]] ; then
    echo "Debug: Did not find the cis domain id of ${BASE_DOMAIN}"
  else
    set +e
    cmd="${IBMCLOUD_CLI} cis dns-records ${domain_id} -i ${ibmcloud_cis_instance_name} | grep -w ${CLUSTER_FILTER}"
    count=$(eval "${cmd} -c")
    set -e
    if [ "${count}" -gt 0 ]; then
      echo "ERROR: remaining cis dns-records..."
      run_command "${cmd}"
      hasError=1
    fi
  fi
fi

exit ${hasError}
