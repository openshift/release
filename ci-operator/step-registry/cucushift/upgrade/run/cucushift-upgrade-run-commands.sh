#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# run upgrade
function upgrade() {
    cmd="oc adm upgrade --to-image=${TARGET_RELEASE} --force=true --allow-explicit-upgrade=true"
    echo "Running command: ${cmd}"
    eval "${cmd}"
}

function monitor_cv() {
    INTERVAL=600
    CNT=12

    while [ $((CNT)) -gt 0 ]; do
        version_full=$(oc get clusterversion/version -o json)
        image=$(echo "${version_full}" | jq -r '.status.history[0].image')
        state=$(echo "${version_full}" | jq -r '.status.history[0].state')
        if [[ "${image}" != "${TARGET_RELEASE}" || "${state}" != "Completed" ]]; then
            echo "Waiting for clusterversion to become ${TARGET_RELEASE}"
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        else
            echo "Cluster is now upgraded to ${TARGET_RELEASE}"
            return 0
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Cluster did not complete upgrade"
            echo "${version_full}"
            return 1
        fi
    done
}

function monitor_mcp() {
    INTERVAL=60
    CNT=10

    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            updated=$(echo "${i}" | awk '{print $3}')
            updating=$(echo "${i}" | awk '{print $4}')
            degraded=$(echo "${i}" | awk '{print $5}')
            machine_cnt=$(echo "${i}" | awk '{print $6}')
            ready_machine_cnt=$(echo "${i}" | awk '{print $7}')
            updated_machine_cnt=$(echo "${i}" | awk '{print $8}')
            degraded_machine_cnt=$(echo "${i}" | awk '{print $9}')

            if [[ "${updated}" == "True" && "${updating}" == "False" && "${degraded}" == "False" && "${machine_cnt}" == "${ready_machine_cnt}" && "${ready_machine_cnt}" == "${updated_machine_cnt}" && $((degraded_machine_cnt)) -eq 0 ]]; then
                READY=true
            else
                echo "Waiting for mcp ${name} to rollout"
                READY=false
            fi
        done <<< "$(oc get mcp --no-headers)"

        if [[ "${READY}" ]]; then
            echo "mcp has successfully rolled out"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "mcp did not successfully roll out"
            oc get mcp
            return 1
        fi
    done
}

function monitor_nodes() {
    INTERVAL=60
    CNT=10

    while [ $((CNT)) -gt 0 ]; do
        READY=false

        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            status=$(echo "${i}" | awk '{print $2}')
            if [[ "${status}" == "Ready" ]]; then
                READY=true
            else
                echo "Waiting for ${name} to become ready"
                READY=false
            fi
        done <<< "$(oc get nodes --no-headers)"

        if [[ "${READY}" ]]; then
            echo "All nodes are have ready status"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Nodes did not become ready"
            oc get nodes
            return 1
        fi
    done
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "RELEASE_IMAGE_INITIAL is ${RELEASE_IMAGE_INITIAL}"
echo "RELEASE_IMAGE_LATEST is ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_TARGET is ${RELEASE_IMAGE_TARGET}"
export TARGET_RELEASE="${RELEASE_IMAGE_TARGET}"

upgrade
sleep "${SLEEP_TIME}"
monitor_cv
monitor_mcp
monitor_nodes
