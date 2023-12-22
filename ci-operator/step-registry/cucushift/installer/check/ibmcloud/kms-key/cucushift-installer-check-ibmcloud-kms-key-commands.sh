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

RESOURCE_GROUP=$(jq -r .ibmcloud.resourceGroupName ${SHARED_DIR}/metadata.json)

ibmcloud_login ${RESOURCE_GROUP}

critical_check_result=0

key_file="${SHARED_DIR}/ibmcloud_key.json"

id=$(jq -r .id ${key_file})
if [[ -z $id ]]; then
    echo "[ERROR] fail to find kp instance id !!"
    exit 1
fi

#check the kpKey whether used in the volumes of the nodes(master & worker)
mapfile -t vols < <(ibmcloud kp registrations -i ${id} -o JSON  | jq -r .[].resourceCrn)
echo "INFO: key registrations list is: ${#vols[@]}" "${vols[@]}"

#check that node os disk is encrypted
machines=$(oc get machines -A --no-headers | awk '{print $2}')
if [[ ! $(echo "${machines}" | wc -l) -gt 0 ]]; then
  echo "ERROR: Fail to find machines ${machines}"
  exit 1
fi

for machine in ${machines}; do
    echo "--- check machine ${machine} ---"
    volCrn=$(ibmcloud is instance ${machine} --output JSON | jq -r .boot_volume_attachment.volume.crn)
    #shellcheck disable=SC2076    
    if [[ -z "${volCrn}" ]] || [[ ! " ${vols[*]} " =~ " ${volCrn} " ]]; then
        echo "ERROR: fail to find the volumn ${volCrn} of ${machine} in the registration list!"
        critical_check_result=1
    fi
done

exit ${critical_check_result}
