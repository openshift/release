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
    echo "Try to login..."
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

ibmcloud_login

#the file which saved the resource group of the pre created dedicated host group (just created when create the pre dedicated host, and not in Default group).
dhgRGFile="${SHARED_DIR}/ibmcloud_resource_group_dhg"
dh_file=${SHARED_DIR}/dedicated_host

if [ -f ${dh_file} ]; then
    dh=$(cat ${dh_file})
    dhgRG=$(cat ${dhgRGFile})
    echo "the pre created dedicated hosts ${dh} in ${dhgRG} resource group."

    mapfile -t allIns < <(ibmcloud is dh ${dh} --output JSON | jq -r .instances[].name)

    for vm in "${allIns[@]}"
    do
        if [[ ! $vm =~ -worker-[0-9]{1}-* && ! $vm =~ -master-[0-9]{1}$ ]]; then
            echo "ERROR: unexpected vm ${vm} in ${allIns[*]}!!"
            exit 1
        fi
    done
else
    infra_id=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
    dhgRG=${infra_id}
    mapfile -t dhs < <(ibmcloud is dhs --resource-group-name ${dhgRG} -q | awk '(NR>1) {print $2}')
    echo "Get the dedicated hosts which created by the installer: ${dhs[*]} in resource group : ${dhgRG}"
    if [[ ${#dhs[@]} != 2 ]]; then
        echo "ERROR: Expect get 2 dedicated host created by cluster in resource group ${dhgRG}!"
        run_command "ibmcloud is dhs --all-resource-groups"
        exit 1
    fi
    dhWorkerHeader="${infra_id}-dhost-compute-"
    if [[ ${dhs[0]} == ${dhWorkerHeader}* ]]; then
        dhMaster=${dhs[1]}
        dhWorker=${dhs[0]}
    elif [[ ${dhs[1]} == ${dhWorkerHeader}* ]]; then
        dhMaster=${dhs[0]}
        dhWorker=${dhs[1]}
    else
        echo "ERROR: fail to get the expected dedicated host [ ${dhWorkerHeader} ] in " "${dhs[@]}"
        exit 1
    fi
    mapfile -t masterIns < <(ibmcloud is dh ${dhMaster} --output JSON | jq -r .instances[].name)
    mapfile -t workerIns < <(ibmcloud is dh ${dhWorker} --output JSON | jq -r .instances[].name)

    echo "created master vm: ${#masterIns[@]} " "${masterIns[@]}"
    echo "created worker vm: ${#workerIns[@]} " "${workerIns[@]}"

    for vm in "${workerIns[@]}"
    do
        if [[ ! $vm =~ -worker-[0-9]{1}-* ]]; then
            echo "ERROR: unexpected vm ${vm} on " "${workerIns[@]}" ", worker vm is expected!!"
            exit 1
        fi
    done

    for vm in "${masterIns[@]}"
    do
        if [[ ! $vm =~ -master-[0-9]{1}$ ]]; then
            echo "ERROR: unexpected vm ${vm} on " "${masterIns[@]}" ", master vm is expected!!"
            exit 1
        fi
    done
fi

echo "Check all nodes PASS"
