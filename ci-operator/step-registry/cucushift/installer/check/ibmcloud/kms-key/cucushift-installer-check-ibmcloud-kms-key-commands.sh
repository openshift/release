#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function unset_proxy () {
    if test -s "${SHARED_DIR}/unset-proxy.sh" ; then 
        echo "unset the proxy"
        echo "source ${SHARED_DIR}/unset-proxy.sh"
        source "${SHARED_DIR}/unset-proxy.sh"
    else  
        echo "no proxy setting found."
    fi        
} 

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

echo "ControlPlane EncryptionKey: ${IBMCLOUD_CONTROL_PLANE_ENCRYPTION_KEY}"
echo "Compute EncryptionKey: ${IBMCLOUD_COMPUTE_ENCRYPTION_KEY}"
echo "DefaultMachinePlatform EncryptionKey: ${IBMCLOUD_DEFAULT_MACHINE_ENCRYPTION_KEY}"

cat ${key_file}

id_m=""
id_w=""
id_d=""

if [[ "${IBMCLOUD_DEFAULT_MACHINE_ENCRYPTION_KEY}" == "true" ]]; then
    id_w=$(jq -r .default.id ${key_file})
    id_m=${id_w}
    id_d=${id_w}
fi

if [[ "${IBMCLOUD_CONTROL_PLANE_ENCRYPTION_KEY}" == "true" ]]; then
    id_m=$(jq -r .master.id ${key_file})
fi

if [[ "${IBMCLOUD_COMPUTE_ENCRYPTION_KEY}" == "true" ]]; then
    id_w=$(jq -r .worker.id ${key_file})
fi

if [[ -z $id_m ]] && [[ -z $id_w ]] && [[ -z $id_d ]]; then
    echo "[WARN] have not specify the Encryption Key for masters workers or default !!"
    exit 0
fi

#check the kpKey whether used in the volumes of the nodes(master & worker)
if [[ -n ${id_m} ]]; then
    mapfile -t vols_m < <(ibmcloud kp registrations -i ${id_m} -o JSON  | jq -r .[].resourceCrn)
    echo "INFO: master key registrations list is: ${#vols_m[@]}" "${vols_m[@]}"
    #check that node os disk is encrypted
    set_proxy
    machines=$(oc get machines.machine.openshift.io -A --no-headers | grep master | awk '{print $2}')
    unset_proxy
    if [[ ! $(echo "${machines}" | wc -l) -gt 0 ]]; then
        echo "ERROR: Fail to find master machines ${machines}"
        critical_check_result=1
    fi
    echo "check the master nodes..."
    for machine in ${machines}; do
        echo "--- check machine ${machine} ---"
        volCrn=$(ibmcloud is instance ${machine} --output JSON | jq -r .boot_volume_attachment.volume.crn)
        #shellcheck disable=SC2076    
        if [[ -z "${volCrn}" ]] || [[ ! " ${vols_m[*]} " =~ " ${volCrn} " ]]; then
            echo "ERROR: fail to find the volumn ${volCrn} of ${machine} in the registration list!"
            critical_check_result=1
        fi
    done
fi

if [[ -n ${id_w} ]]; then
    mapfile -t vols_w < <(ibmcloud kp registrations -i ${id_w} -o JSON  | jq -r .[].resourceCrn)
    echo "INFO: worker key registrations list is: ${#vols_w[@]}" "${vols_w[@]}"
    set_proxy
    machines=$(oc get machines.machine.openshift.io -A --no-headers | grep worker | awk '{print $2}')
    unset_proxy
    if [[ ! $(echo "${machines}" | wc -l) -gt 0 ]]; then
        echo "ERROR: Fail to find worker machines ${machines}"
        critical_check_result=1
    fi
    echo "check the worker nodes..."
    for machine in ${machines}; do
        echo "--- check machine ${machine} ---"
        volCrn=$(ibmcloud is instance ${machine} --output JSON | jq -r .boot_volume_attachment.volume.crn)
        #shellcheck disable=SC2076    
        if [[ -z "${volCrn}" ]] || [[ ! " ${vols_w[*]} " =~ " ${volCrn} " ]]; then
            echo "ERROR: fail to find the volumn ${volCrn} of ${machine} in the registration list!"
            critical_check_result=1
        fi
    done
fi

if [[ -n ${id_d} ]]; then
    mapfile -t vols_d < <(ibmcloud kp registrations -i ${id_d} -o JSON  | jq -r .[].resourceCrn)
    echo "INFO: default key registrations list is: ${#vols_d[@]}" "${vols_d[@]}"
    vols=$(ibmcloud is vols --encryption user_managed | grep data | awk '{print $1}')
    if [[ ! $(echo "${vols}" | wc -l) -gt 0 ]] && [[ ${#vols_d[@]} -gt 0 ]] ; then
        echo "[ERROR] fail not found the user_managed data volumes"
        critical_check_result=1
    fi
    echo "check the data volume ..."
    for vol in ${vols}; do 
        echo "---check volume ${vol} ---"
        volCrn=$(ibmcloud is vol $vol --output JSON | jq -r .crn)
        #shellcheck disable=SC2076    
        if [[ -z "${volCrn}" ]] || [[ ! " ${vols_d[*]} " =~ " ${volCrn} " ]]; then
            echo "ERROR: fail to find the volumn ${volCrn} in the registration list!"
            critical_check_result=1
        fi
    done
fi
exit ${critical_check_result}
