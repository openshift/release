#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

function check_latest_machineconfig_applied() {
    local role="$1" cmd latest_machineconfig applied_machineconfig_machines ready_machines

    cmd="oc get machineconfig"
    echo "Command: $cmd"
    eval "$cmd"

    echo "Checking $role machines are applied with latest $role machineconfig..."
    latest_machineconfig=$(oc get machineconfig --sort-by='{.metadata.creationTimestamp}' | grep "rendered-${role}-" | tail -1 | awk '{print $1}')
    if [[ ${latest_machineconfig} == "" ]]; then
        echo >&2 "Did not found ${role} render machineconfig"
        return 1
    else
        echo "latest ${role} machineconfig: ${latest_machineconfig}"
    fi

    applied_machineconfig_machines=$(oc get node -l "node-role.kubernetes.io/${role}" -o json | jq -r --arg mc_name "${latest_machineconfig}" '.items[] | select(.metadata.annotations."machineconfiguration.openshift.io/state" == "Done" and .metadata.annotations."machineconfiguration.openshift.io/currentConfig" == $mc_name) | .metadata.name' | sort)
    ready_machines=$(oc get node -l "node-role.kubernetes.io/${role}" -o json | jq -r '.items[].metadata.name' | sort)
    if [[ ${applied_machineconfig_machines} == "${ready_machines}" ]]; then
        echo "latest machineconfig - ${latest_machineconfig} is already applied to ${ready_machines}"
        return 0
    else
        echo "latest machineconfig - ${latest_machineconfig} is applied to ${applied_machineconfig_machines}, but expected ready node lists: ${ready_machines}"
        return 1
    fi
}

function wait_machineconfig_applied() {
    local role="${1}" try=0 interval=60
    num=$(oc get node --no-headers -l node-role.kubernetes.io/"$role"= | wc -l)
    local max_retries; max_retries=$((num*10))
    while (( try < max_retries )); do
        echo "Checking #${try}"
        if ! check_latest_machineconfig_applied "${role}"; then
            sleep ${interval}
        else
            break
        fi
        (( try += 1 ))
    done
    if (( try == max_retries )); then
        echo >&2 "Timeout waiting for all $role machineconfigs are applied"
        return 1
    else
        echo "All ${role} machineconfigs check PASSED"
        return 0
    fi
}

function wait_machineconfig_generated() {
    local latest_mc_before="${1}" role="${2}" try=0 interval=60 max_retries=5

    while (( try < max_retries )); do
        latest_mc_after=$(oc get machineconfig --sort-by='{.metadata.creationTimestamp}' | grep "rendered-${role}-" | tail -1 | awk '{print $1}')
        if [[ "${latest_mc_before}" == "${latest_mc_after}" ]]; then
            echo "Latest machineconfig for ${role} is not generated, wait 1 min..."
            sleep ${interval}
        else
            echo "Latest machineconfig for ${role} is generated - ${latest_mc_after}"
            break
        fi
        (( try += 1 ))
    done

    if (( try == max_retries )); then
        echo >&2 "Timeout waiting for $role new machineconfigs generating!"
        return 1
    else
        return 0
    fi
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

latest_mc_master_before=$(oc get machineconfig --sort-by='{.metadata.creationTimestamp}' | grep "rendered-master-" | tail -1 | awk '{print $1}')
latest_mc_worker_before=$(oc get machineconfig --sort-by='{.metadata.creationTimestamp}' | grep "rendered-worker-" | tail -1 | awk '{print $1}')

# Apply patch to enable featureset
echo "Apply patch to enable featureset: ${POST_FEATURE_SET}"
oc patch featuregate cluster --type merge -p "{\"spec\":{\"featureSet\":\"${POST_FEATURE_SET}\"}}" -ojson

# Waiting new mc is generated
wait_machineconfig_generated "${latest_mc_master_before}" "master"
wait_machineconfig_generated "${latest_mc_worker_before}" "worker"

echo "Make sure all machines are applied with latest machineconfig"
wait_machineconfig_applied "master"
wait_machineconfig_applied "worker"
