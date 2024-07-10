#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; debug' EXIT TERM

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "Describing abnormal mcp...\n"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

function unpause() {
    oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/worker
    ret=$(oc get machineconfigpools worker -ojson| jq .spec.paused)
    if [[ "${ret}" != "false" ]]; then
        echo >&2 "Failed to resume worker pool, exiting..." && return 1
    fi
}

function check_mcp() {
    local out updated updating degraded try=0 max_retries=30
    while (( try < max_retries )); 
    do
        echo "Checking worker pool status #${try}..."
        run_command "oc get machineconfigpools"
        out="$(oc get machineconfigpools worker --no-headers)"
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"
    
        if [[ ${updated} == "True" && ${updating} == "False" && ${degraded} == "False" ]]; then
            echo "Worker pool status check passed" && return 0
        fi  
        sleep 120
        (( try += 1 ))
    done  
    echo >&2 "Worker pool status check failed" && return 1
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}


if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

unpause
if [[ $(oc get nodes -l node.openshift.io/os_id=rhel) != "" ]]; then
    echo "Found rhel worker, this step is supposed to be used in eus upgrade, skipping mcp checking here, need to check it after rhel worker upgraded..."
    run_command "oc get machineconfigpools"
    run_command "oc get node -owide"
else
    check_mcp
fi
