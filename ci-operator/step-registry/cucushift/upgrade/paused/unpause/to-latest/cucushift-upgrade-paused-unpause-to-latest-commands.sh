#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function unpause() {
    echo "Resume worker pool..."
    oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/worker
    ret=$(oc get mcp worker -ojson| jq .spec.paused)
    if [[ "${ret}" != "false" ]]; then
        echo >&2 "Failed to resume worker pool, exiting..." && return 1
    fi
}

function check_mcp() {
    local out updated updating degraded try=0 max_retries=30
    echo -e "oc get mcp\n$(oc get mcp)"
    while (( try < max_retries )); 
    do
        echo "Checking worker pool status #${try}..."
        out="$(oc get mcp worker --no-headers)"
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"
    
        if [[ ${updated} == "True" && ${updating} == "False" && ${degraded} == "False" ]]; then
            echo "Worker pool status check passed" && return 0
        fi  
        sleep 60
        (( try += 1 ))
    done  
    echo >&2 "Worker pool status check failed" && return 1
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

unpause
check_mcp
