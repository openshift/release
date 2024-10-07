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

# unpause the paused mcp
function unpause() {
    echo "Unpause the paused mcp..."
    local mcp="$1" ret
    oc patch --type=merge --patch='{"spec":{"paused":false}}' mcp/${mcp}
    if [ $? -ne 0 ]; then
        echo "Unpause mcp failed"
        exit 1
    fi

    ret=$(oc get machineconfigpools ${mcp} -ojson | jq -r '.spec.paused')
    if [[ "${ret}" != "false" ]]; then
        echo >&2 "${mcp} pool failed to unpause, exiting" && exit 1
    fi
}

function check_mcp() {
    local mcp="$1" expected_status="$2"
    local out updated updating degraded try=0 max_retries=30
    echo "Checking mcp ${mcp}, expected status ${expected_status}..."
    while (( try < max_retries )); 
    do
        sleep 300
        echo "Checking ${mcp} pool status #${try}..."
        out="$(oc get machineconfigpools ${mcp} --no-headers)"
        echo $out
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"
    
        if [[ "${updated}" == "${expected_status}" && ${updating} == "False" && ${degraded} == "False" ]]; then
            echo -e "${mcp} pool status check passed\n" && return 0
        fi  
        (( try += 1 ))
    done
    printf "\n"
    run_command "oc get machineconfigpools"
    run_command "oc get node -owide"
    printf "\n"
    echo >&2 "MCP status check failed" && exit 1
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

# get all normal mcp
actual_mcp=$(oc get mcp --output jsonpath="{.items[*].metadata.name}")
IFS=" " read -r -a actual_mcp_arr <<<"$actual_mcp"
echo -e "all observed mcps: ${actual_mcp_arr[*]}\n"
normal_mcp_arr=()
for mcp in "${actual_mcp_arr[@]}"
do
    if [[ ! " ${PAUSED_MCP_NAME} " =~ [[:space:]]${mcp}[[:space:]] ]]; then
        normal_mcp_arr+=("$mcp")
    fi
done
echo -e "all normal mcps: ${normal_mcp_arr[*]} \n"

for mcp in "${normal_mcp_arr[@]}"
do
    check_mcp ${mcp} "True"
done
IFS=" " read -r -a arr <<<"$PAUSED_MCP_NAME"
for mcp in "${arr[@]}";
do
    check_mcp $mcp "False"
    printf "\n"
    unpause ${mcp}
    printf "\n"
    if [[ $(oc get nodes -l node.openshift.io/os_id=rhel) != "" ]]; then
        echo "Found rhel worker, this step is supposed to be used in eus upgrade, skipping mcp checking here, need to check it after rhel worker upgraded..."
        run_command "oc get machineconfigpools"
        run_command "oc get node -owide"
    else
        check_mcp ${mcp} "True"
    fi
done