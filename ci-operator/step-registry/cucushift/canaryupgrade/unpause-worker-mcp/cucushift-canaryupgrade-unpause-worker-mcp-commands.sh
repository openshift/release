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

# After upgrading, the paused mcp should not be upgraded, so its version is not same with unpaused mcp
function pre_check_mcp(){
    local paused_worker_version running_worker_version
    paused_worker_version=$(oc get -l 'node-role.kubernetes.io/'${PAUSED_MCP_LABEL}'=' nodes -ojson | jq '.items[0].status.nodeInfo' | jq -r '.containerRuntimeVersion,.kernelVersion,.osImage')
    running_worker_version=$(oc get -l 'node-role.kubernetes.io/'${PAUSED_MCP_LABEL}'!=' nodes -ojson | jq '.items[0].status.nodeInfo' | jq -r '.containerRuntimeVersion,.kernelVersion,.osImage')

    if [[ $paused_worker_version == $running_worker_version ]]; then
        echo "Paused worker and unpaused worker have same version, it is not corect."
        return 1
    fi
}

# After all mcp upgraded, all worker should on same version
function post_check_mcp(){
    local paused_worker_version running_worker_version
    paused_worker_version=$(oc get -l 'node-role.kubernetes.io/'${PAUSED_MCP_LABEL}'=' nodes -ojson | jq '.items[0].status.nodeInfo' | jq -r '.containerRuntimeVersion,.kernelVersion,.osImage')
    running_worker_version=$(oc get -l 'node-role.kubernetes.io/'${PAUSED_MCP_LABEL}'!=' nodes -ojson | jq '.items[0].status.nodeInfo' | jq -r '.containerRuntimeVersion,.kernelVersion,.osImage')

    if [[ $paused_worker_version != $running_worker_version ]]; then
        echo "Paused worker and unpaused worker should have same version but actually not."
        return 1
    fi
}

# After upgrading, the unpaused mcp should be upgraded
function check_unpaused_mcp() {
    local label
    tag=$(oc get -l 'node-role.kubernetes.io/'${PAUSED_MCP_LABEL}'!=,node-role.kubernetes.io/master!=' nodes -ojson | jq -r '.items[0].metadata.labels' | grep 'node-role.kubernetes.io/mcp')
    old_IFS="$IFS"
    IFS="/"
    arr=($tag)
    arr_key=${arr[1]}
    IFS="\""
    new_arr=($arr_key)
    label=${new_arr[0]} # "node-role.kubernetes.io/mcpbar"
    IFS="$old_IFS"

    local out updated updating degraded try=0 max_retries=30

    while (( try < max_retries )); 
    do
        echo "Checking unpaused worker pool status #${try}..."
        run_command "oc get machineconfigpools ${label}"
        out="$(oc get machineconfigpools ${label} --no-headers)"
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"
    
        if [[ ${updated} == "True" && ${updating} == "False" && ${degraded} == "False" ]]; then
            echo "Unpaused worker pool status check passed" && return 0
        fi  
        sleep 120
        (( try += 1 ))
    done  
    echo >&2 "Unpaused worker pool status check failed" && return 1
}

# unpaused the paused mcp
function unpause() {
    run_command "oc patch --type=merge --patch='{\"spec\":{\"paused\":false}}' mcp/${PAUSED_MCP_LABEL}"
    if [ $? -ne 0 ]; then
        echo "Unpause mcp failed"
        return 1
    fi

    ret=$(oc get machineconfigpools ${PAUSED_MCP_LABEL} -ojson | jq -r '.spec.paused')
    if [[ "${ret}" != "false" ]]; then
        echo >&2 "${PAUSED_MCP_LABEL} pool failed to unpause, exiting" && return 1
    fi
}

function wait_paused_worker_upgraded(){
    local wait_upgrade=20
    while (( wait_upgrade > 0 )); do
        sleep 1m
        out="$(oc get machineconfigpools ${PAUSED_MCP_LABEL} --no-headers)"
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"

        if [[ ${updated} == "True" && ${updating} == "False" && ${degraded} == "False" ]]; then
            echo "Unpaused worker pool status already updated" && return 0
        fi
        wait_upgrade=$(( wait_upgrade - 1 ))
    done
}

function remove_mcp_label(){
    echo "Remove mcp label..."
    local worker worker_list worker_size
    worker=$(oc get -l 'node-role.kubernetes.io/master!=' -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' nodes)
    worker_list=(${worker})

    worker_size=${#worker_list[@]}
    if [[ $worker_size -lt 2 ]]; then 
        echo 'There are no enough worker nodes for canary upgrade, requires at lease 2 worker nodes'; 
        exist 1
    fi

    # not sure if worders have same order
    for i in "${!worker_list[@]}"; do
        node=${worker_list[i]}
        if [[ $i -le $worker_size/2 ]]; then
            run_command "oc label node ${node} node-role.kubernetes.io/mcpfoo-"
        else
            run_command "oc label node ${node} node-role.kubernetes.io/mcpbar-"
        fi
    done

    local wait_upgrade=120
    while (( wait_upgrade > 0 )); do
        echo "Wait worker mcp reconciled back..."
        sleep 10
        out="$(oc get machineconfigpools worker --no-headers)"
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"
        MACHINECOUNT="$(echo "${out}" | awk '{print $6}')"
        READYMACHINECOUNT="$(echo "${out}" | awk '{print $7}')"
        UPDATEDMACHINECOUNT="$(echo "${out}" | awk '{print $8}')"
        DEGRADEDMACHINECOUNT="$(echo "${out}" | awk '{print $9}')"

        if [[ ${updated} == "True" && ${updating} == "False" && ${degraded} == "False" 
            && ${MACHINECOUNT} == ${worker_size} && ${READYMACHINECOUNT} == ${worker_size} && ${UPDATEDMACHINECOUNT} == ${worker_size} && ${DEGRADEDMACHINECOUNT} == 0
        ]]; then
            echo "Worker pool reconciled back" && return 0
        fi
        wait_upgrade=$(( wait_upgrade - 1 ))
    done
    return 1
}

function delete_mcp(){
    run_command "oc delete mcp mcpbar mcpfoo"
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

pre_check_mcp
check_unpaused_mcp
unpause
wait_paused_worker_upgraded
post_check_mcp
remove_mcp_label
delete_mcp
