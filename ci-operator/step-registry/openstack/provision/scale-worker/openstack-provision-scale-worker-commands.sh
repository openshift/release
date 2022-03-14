#!/usr/bin/env bash

set -Eeuo pipefail

function wait_for_worker_machines() {
    INTERVAL=10
    CNT=180

    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            status=$(echo "${i}" | awk '{print $2}')
            if [[ "${status}" == "Ready" ]]; then
                echo "Worker ${name} is ready"
                READY=true
            else
                echo "Waiting for the worker to be ready"
            fi
        done <<< "$(oc get node --no-headers -l node-role.kubernetes.io/worker | grep -v master)"

        if [[ ${READY} == "true" ]]; then
            echo "Worker is ready"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Timed out waiting for worker to be ready"
            oc get node
            return 1
        fi
    done
}

WORKER_SCALE=${WORKER_SCALE:-1}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

WORKER_MACHINESET=$(oc get machineset -n openshift-machine-api | grep worker | awk '{print $1}')
echo "Scaling up workers to ${WORKER_SCALE}"
oc scale --replicas="${WORKER_SCALE}" machineset "${WORKER_MACHINESET}" -n openshift-machine-api
wait_for_worker_machines

echo "Disable mastersSchedulable since we now have dedicated worker nodes"
oc patch Scheduler cluster --type=merge --patch '{ "spec": { "mastersSchedulable": false } }'
sleep 10

echo "Worker nodes are ready!"
