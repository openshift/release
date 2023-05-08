#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function check_latest_machineconfig_applied() {
    local role="$1" cmd latest_machineconfig applied_machineconfig_machines ready_machines

    cmd="oc get machineconfig"
    echo "Command: $cmd"
    eval "$cmd"

    echo "Checking $role machines are applied with latest $role machineconfig..."
    # in case of rollback, latest machineconfig is not the one with the last timestamp. using mcp spec instead.
    #latest_machineconfig=$(oc get machineconfig --sort-by='{.metadata.creationTimestamp}' | grep "rendered-${role}-" | tail -1 | awk '{print $1}')
    latest_machineconfig=$(oc get mcp -o json | jq -r --arg role_label "node-role.kubernetes.io/${role}" '.items[] | select(.spec.nodeSelector.matchLabels[$role_label] == "") | .spec.configuration.name')

    if [[ -z ${latest_machineconfig} ]]; then
        echo >&2 "Did not found ${role} render machineconfig"
        return 1
    else
        echo "latest ${role} machineconfig: ${latest_machineconfig}"
    fi
    
    applied_machineconfig_machines=$(oc get node -l "node-role.kubernetes.io/${role}" -o json | jq -r --arg mc_name "${latest_machineconfig}" '.items[] | select(.metadata.annotations."machineconfiguration.openshift.io/state" == "Done" and .metadata.annotations."machineconfiguration.openshift.io/currentConfig" == $mc_name) | .metadata.name' | sort)
    ready_machines=$(oc get node -l "node-role.kubernetes.io/${role}" -o json | jq -r '.items[].metadata.name' | sort)
    if [[ "${applied_machineconfig_machines}" == "${ready_machines}" ]]; then
        echo "latest machineconfig - ${latest_machineconfig} is already applied to ${ready_machines}"
        return 0
    else
        echo >&2 "latest machineconfig - ${latest_machineconfig} is applied to ${applied_machineconfig_machines}, but expected ready node lists: ${ready_machines}"
        return 1
    fi
}

function wait_machineconfig_applied() {
    local role="${1}" try=0 interval=60
    num=$(oc get node --no-headers -l node-role.kubernetes.io/"$role"= | wc -l)
    local max_retries; max_retries=$(expr $num \* 10)
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

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc null_version unavailable_operator degraded_operator skip_operator

    local skip_operator="aro" # ARO operator versioned but based on RP git commit ID not cluster version

    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    oc get clusteroperator >"${tmp_clusteroperator}"
    column=$(head -n 1 "${tmp_clusteroperator}" | awk '{print NF}')
    last_column_name=$(head -n 1 "${tmp_clusteroperator}" | awk '{print $NF}')
    if [[ ${last_column_name} == "MESSAGE" ]]; then
        (( column -= 1 ))
        tmp_clusteroperator_1=$(mktemp /tmp/health_check-script.XXXXXX)
        awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' "${tmp_clusteroperator}" > "${tmp_clusteroperator_1}"
        input="${tmp_clusteroperator_1}"
    fi

    while IFS= read -r line
    do
        rc=$(echo "${line}" | awk '{print NF}')
        if (( rc != column )); then
            echo >&2 "The following line have empty column"
            echo >&2 "${line}"
            (( tmp_ret += 1 ))
        fi
    done < "${input}"
    rm -f "${tmp_clusteroperator}"

    echo "Make sure every operator column reports version"
    if null_version=$(oc get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
      echo >&2 "Null Version: ${null_version}"
      (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator reports correct version"
    if incorrect_version=$(oc get clusteroperator --no-headers | grep -v ${skip_operator} | awk -v var="${EXPECTED_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
        echo >&2 "Incorrect CO Version: ${incorrect_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(oc get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Available") | .status' | grep -iv "True"; then
        echo >&2 "Some operators are unavailable, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's PROGRESSING column is False"
    if progressing_operator=$(oc get clusteroperator | awk '$4 == "True"' | grep "True"); then
        echo >&2 "Some operator's PROGRESSING is True"
        echo >&2 "$progressing_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
        echo >&2 "Some operators are unavailable, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    if degraded_operator=$(oc get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False'; then
        echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    return $tmp_ret
}

function wait_clusteroperators_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=3 max_retries=20
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        if check_clusteroperators; then
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        else
            echo "cluster operators are not ready yet, wait and retry..."
            continous_successful_check=0
        fi
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some cluster operator does not get ready or not stable"
        echo "Debug: current CO output is:"
        oc get co
        return 1
    else
        echo "All cluster operators status check PASSED"
        return 0
    fi
}

function check_mcp() {
    local updating_mcp unhealthy_mcp

    updating_mcp=$(oc get mcp -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status --no-headers | grep -v "False")
    if [[ -n "${updating_mcp}" ]]; then
        echo "Some mcp is updating..."
        echo "${updating_mcp}"
        return 1
    fi

    # Do not check UPDATED on purpose, beause some paused mcp would not update itself until unpaused
    unhealthy_mcp=$(oc get mcp -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount --no-headers | grep -v "False.*False.*0")
    if [[ -n "${unhealthy_mcp}" ]]; then
        echo "Detected unhealthy mcp:"
        echo "${unhealthy_mcp}"
        echo "Real-time detected unhealthy mcp:"
        oc get mcp -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount | grep -v "False.*False.*0"
        echo "Real-time full mcp output:"
        oc get mcp
        echo ""
        unhealthy_mcp_names=$(echo "${unhealthy_mcp}" | awk '{print $1}')
        echo "Using oc describe to check status of unhealthy mcp ..."
        for mcp_name in ${unhealthy_mcp_names}; do
          echo "Name: $mcp_name"
          oc describe mcp $mcp_name || echo "oc describe mcp $mcp_name failed"
        done
        return 2
    fi
    return 0
}

function wait_mcp_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=3 max_retries=20 ret=0
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        ret=0
        check_mcp || ret=$?
        if [[ "$ret" == "0" ]]; then
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        elif [[ "$ret" == "1" ]]; then
            echo "Some machines are updating..."
            continous_successful_check=0
        else
            echo "Some machines are degraded..."
            break
        fi
        echo "wait and retry..."
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some mcp does not get ready or not stable"
        echo "Debug: current mcp output is:"
        oc get mcp
        return 1
    else
        echo "All mcp status check PASSED"
        return 0
    fi
}

function check_node() {
    local node_number ready_number
    node_number=$(oc get node --no-headers | wc -l)
    ready_number=$(oc get node --no-headers | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node --no-headers | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function check_pod() {
    local soptted_pods

    soptted_pods=$(oc get pod --all-namespaces | grep -Evi "running|Completed" |grep -v NAMESPACE)
    if [[ -n "$soptted_pods" ]]; then
        echo "There are some abnormal pods:"
        echo "${soptted_pods}"
    fi
    echo "Show all pods for reference/debug"
    run_command "oc get pods --all-namespaces"
}


# Check version, state in history
function check_history() {
    local cv version state
    cv=$(oc get clusterversion/version -o json)
    version=$(echo "${cv}" | jq -r '.status.history[0].version')
    state=$(echo "${cv}" | jq -r '.status.history[0].state')
    if [[ ${version} == "${EXPECTED_VERSION}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster verson is ${EXPECTED_VERSION}" && return 0
    else
        echo >&2 "History check FAILED, cluster is being expected on ${TARGET_VERSION}, but current version is ${version}, exiting" && return 1
    fi
}

###Main###
if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -z "${EXPECTED_VERSION}" ]]; then
    EXPECTED_VERSION=$(oc get clusterversion/version -o json | jq -r '.status.history[0].version')
fi

check_history || exit 1

echo "Step #1: Make sure all machines are applied with latest machineconfig"
#if wait_machineconfig_applied "master"; then
#    echo "masters are already applied with latest machineconfig"
#else
#    echo >&2 "some masters are not applied with latest machineconfig"
#    exit 1
#fi
#
#worker_num=$(oc get mcp -o json | jq -r --arg role_label "node-role.kubernetes.io/worker" '.items[] | select(.spec.nodeSelector.matchLabels[$role_label] == "") | .status.machineCount')
#if [[ "${worker_num}" == "0" ]]; then
#    echo "This is a compact or single-node cluster, skip chcking workers..."
#else
#    if wait_machineconfig_applied "worker"; then
#        echo "workers are already applied with latest machineconfig"
#    else
#        echo >&2 "some workers are not applied with latest machineconfig"
#        exit 1
#    fi
#fi
wait_mcp_continous_success || exit 1


echo "Step #2: check all cluster operators get stable and ready"
wait_clusteroperators_continous_success || exit 1

echo "Step #3: Make sure every machine is in 'Ready' status"
check_node || exit 1

echo "Step #4: check all pods are in status running or complete"
check_pod || exit 1
