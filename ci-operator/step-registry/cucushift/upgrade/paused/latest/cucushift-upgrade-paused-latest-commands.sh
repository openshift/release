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
        oc get mcp --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

# Extract oc binary which is supposed to be identical with target release
function extract_oc(){
    echo -e "Extracting oc\n"
    local retry=5 tmp_oc="/tmp/client-2"
    mkdir -p ${tmp_oc}
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=oc --to=${tmp_oc} ${TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    which oc
    oc version --client
    return 0
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response
    digest="$(echo "${TARGET}" | cut -f2 -d@)"
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    response=$(curl --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
    if (( response == 200 )); then
        echo "${TARGET} is signed" && return 0
    else
        echo "Seem like ${TARGET} is not signed" && return 1
    fi
}

# Check if admin ack is required before upgrade
function admin_ack() {
    local out; out="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
    if [[ ${out} != *"ack-4.${SOURCE_MINOR_VERSION}"* ]]; then
        echo "Admin ack not required" && return
    fi

    echo "Require admin ack"
    local wait_time_loop_var=0 ack_data
    ack_data="$(echo "${out}" | jq -r "keys[]")"
    for ack in ${ack_data};
    do
        # e.g.: ack-4.12-kube-1.26-api-removals-in-4.13
        if [[ "${ack}" == *"ack-4.${SOURCE_MINOR_VERSION}"* ]]
        then
            echo "Admin ack patch data is: ${ack}"
            oc -n openshift-config patch configmap admin-acks --patch '{"data":{"'"${ack}"'": "true"}}' --type=merge
        fi
    done

    echo "Admin-acks patch gets started"

    echo -e "sleep 5 min wait admin-acks patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "AdminAckRequired"; then
            echo -e "Admin-acks patch PASSED\n"
            return 0
        else
            echo -e "Admin-acks patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for admin-acks completing, exiting" && return 1
    fi
}

function pause_worker_mcp() {
    echo "Pausing worker pool..."
    oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/worker
    ret=$(oc get mcp worker -ojson | jq -r '.spec.paused')
    if [[ "${ret}" != "true" ]]; then
        echo >&2 "Worker pool failed to pause, exiting" && return 1
    fi
}

# Upgrade the cluster to target release
function upgrade() {
    oc adm upgrade --to-image="${TARGET}" --allow-explicit-upgrade --force="${FORCE_UPDATE}"
    echo "Upgrading cluster to ${TARGET} gets started..."
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" out avail progress
    echo "Starting the upgrade checking on $(date "+%F %T")"
    while (( wait_upgrade > 0 )); do
        sleep 5m
        wait_upgrade=$(( wait_upgrade - 5 ))
        if ! ( run_command "oc get clusterversion" ); then
            continue
        fi
        if ! out="$(oc get clusterversion --no-headers)"; then continue; fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${TARGET_VERSION}" ]]; then
            echo -e "Upgrade succeed on $(date "+%F %T")\n\n"
            return 0
        fi
    done
    if [[ ${wait_upgrade} -le 0 ]]; then
        echo -e "Upgrade timeout on $(date "+%F %T"), exiting\n" && return 1
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function run_command_oc_retries() {
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

    # In disconnected install, marketplace often get into False state, so it is better to remove it from cluster from flexy post-action
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

    # In disconnected install, openshift-sample often get into Degrade state, so it is better to remove them from cluster from flexy post-action
    #degraded_operator=$(${OC} get clusteroperator | grep -v "openshift-sample" | awk '$5 == "True"')
    if degraded_operator=$(${OC} get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    #co_check=$(${OC} get clusteroperator -o json | jq '.items[] | select(.metadata.name != "openshift-samples") | .status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False')
    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False'; then
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
        echo "Debug: current clusterverison output is:"
        oc get clusterversion
        return 1
    else
        echo "All cluster operators status check PASSED"
        return 0
    fi
}

function check_node() {
    local node_number ready_number
    node_number=$(${OC} get node |grep -vc STATUS)
    ready_number=$(${OC} get node |grep -v STATUS | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node |grep -v STATUS | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function check_mcp() {
    local out updated updating degraded arr
    arr=("master" "worker")
    echo -e "oc get mcp\n$(oc get mcp)"
    for i in "${arr[@]}"; 
    do
        echo "Checking ${i} pool status..."
        out="$(${OC} get mcp ${i} --no-headers)"
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"
    
        if [[ ${i} == "master" ]]; then
            if [[ ${updated} == "True" && ${updating} == "False" && ${degraded} == "False" ]]; then
                echo "Master pool status check passed"
            else
                echo >&2 "Master pool status check failed" && return 1
            fi
        else
            if [[ ${updated} == "False" && ${updating} == "False" && ${degraded} == "False" ]]; then
                echo "Worker pool status check passed"
            else
                echo >&2 "Worker pool status check failed" && return 1
            fi 
        fi   
    done      
}

function health_check() {
    check_mcp
    wait_clusteroperators_continous_success
    check_node
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Target version oc will be extract in the /tmp/client directory, use it first
mkdir -p /tmp/client 
export OC_DIR="/tmp/client"
export PATH=${OC_DIR}:$PATH

export OC="run_command_oc_retries"

SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
SOURCE_MINOR_VERSION="$(echo "${SOURCE_VERSION}" | cut -f2 -d.)"
export SOURCE_MINOR_VERSION

export TARGET="${RELEASE_IMAGE_TARGET}"
TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
export TARGET_VERSION
echo -e "Target release version is: ${TARGET_VERSION}"

extract_oc
export FORCE_UPDATE="false"
if ! check_signed; then
    echo "You're updating to an unsigned images, you must override the verification using --force flag"
    FORCE_UPDATE="true"
else
    admin_ack
fi
upgrade
check_upgrade_status
health_check
