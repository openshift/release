#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createArchMigrationJunit; debug' EXIT TERM

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "Describing abnormal mcp...\n"
        oc get mcp --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

# Generate the Junit for migration
function createArchMigrationJunit() {
    echo "Generating the Junit for arch migration"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_arch_migration.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster arch migration" tests="1" failures="0">
  <testcase classname="cluster arch migration" name="arch migration should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_arch_migration.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster arch_migration" tests="1" failures="1">
  <testcase classname="cluster arch migration" name="arch migration should succeed">
    <failure message="">openshift cluster arch migration failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function run_command_oc() {
    local try=0 max=40 ret_val

    if [[ "$#" -lt 1 ]]; then
        return 0
    fi

    while (( try < max )); do
        if ret_val=$(oc "$@" 2>&1); then
            break
        fi
        (( try += 1 ))
        sleep 3
    done

    if (( try == max )); then
        echo >&2 "Run:[oc $*]"
        echo >&2 "Get:[$ret_val]"
        return 255
    fi

    echo "${ret_val}"
}

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc null_version unavailable_operator degraded_operator

    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    ${OC} get clusteroperator >"${tmp_clusteroperator}"
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
    if null_version=$(${OC} get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
        echo >&2 "Null Version: ${null_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator reports correct version"
    if incorrect_version=$(${OC} get clusteroperator --no-headers | awk -v var="${SOURCE_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
        echo >&2 "Incorrect CO Version: ${incorrect_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(${OC} get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Available") | .status' | grep -iv "True"; then
        echo >&2 "Some operators are unavailable, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    if degraded_operator=$(${OC} get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi

    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False'; then
        echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    return $tmp_ret
}

function wait_clusteroperators_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=3 max_retries=40
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

function check_node() {
    local not_ready_number try=0 interval=60 max_retries=40
    while (( try < max_retries )); do
        echo "Checking #${try}"
        not_ready_number=$(${OC} get node |grep -v STATUS | awk '$2 != "Ready"' | wc -l)
        if (( not_ready_number != 0 )); then
            sleep ${interval}
        else
            break
        fi
        (( try += 1 ))
    done
    if (( try == max_retries )); then
        echo >&2 "Timeout waiting for all nodes ready"
        return 1
    else
        echo "All nodes are ready"
        return 0
    fi
}

function check_pod() {
    echo "Show all pods status for reference/debug"
    oc get pods --all-namespaces
}

function health_check() {
    #1. Make sure all machines are applied with latest machineconfig
    echo "Step #1: Make sure all machines are applied with latest machineconfig"
    wait_machineconfig_applied "master"
    wait_machineconfig_applied "worker"

    #2. Check all cluster operators get stable and ready
    echo "Step #2: check all cluster operators get stable and ready"
    wait_clusteroperators_continous_success

    #3. Make sure every machine is in 'Ready' status
    echo "Step #3: Make sure every machine is in 'Ready' status"
    check_node

    #4. All pods are in status running or complete
    echo "Step #4: check all pods are in status running or complete"
    check_pod
}

# Monitor the migration status
function check_migrate_status() {
    local wait_migrate="${TIMEOUT}" out avail progress
    while (( wait_migrate > 0 )); do
        sleep 5m
        (( wait_migrate -= 5 ))
        if ! ( echo "oc get clusterversion" && oc get clusterversion ); then
            continue
        fi
        if ! out="$(oc get clusterversion --no-headers)"; then continue; fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${SOURCE_VERSION}" ]]; then
            echo -e "Migrate succeed\n\n"
            return 0
        fi
    done
    if (( wait_migrate <= 0 )); then
        echo >&2 "Migrate timeout, exiting" && return 1
    fi
}

# Check ClusterVersion has architecture="Multi"
function check_arch() {
    local msg
    msg=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "ReleaseAccepted")|.message')
    if [[ ${msg} == *"architecture=\"Multi\""* ]]; then
        echo "ClusterVersion architecture check PASSED"
    else
        echo >&2 "ClusterVersion architecture check FAILED, exiting" && return 1
    fi
}

function switch_channel() {
    echo "Switch upgrade channel to candidate-${SOURCE_XY_VERSION}..."
    oc adm upgrade channel candidate-${SOURCE_XY_VERSION}
    ret=$(oc get clusterversion/version -ojson | jq -r '.spec.channel')
    if [[ "${ret}" != "candidate-${SOURCE_XY_VERSION}" ]]; then
        echo >&2 "Failed to switch channel, exiting" && return 1
    fi
}

function migrate() {
    echo "Arch migrating"
    cmd="oc adm upgrade --to-multi-arch"
    echo "Migrating cluster: ${cmd}"
    if ! eval "${cmd}"; then
        echo >&2 "Failed to request arch migration, exiting" && return 1
    fi
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export OC="run_command_oc"

SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
SOURCE_XY_VERSION="$(echo "${SOURCE_VERSION}" | cut -f1,2 -d.)"
export SOURCE_VERSION

switch_channel
migrate
check_migrate_status
check_arch
health_check
