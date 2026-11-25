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

function pause() {
    echo "Pausing worker pool..."
    local mcp="$1" ret
    oc patch --type=merge --patch='{"spec":{"paused":true}}' mcp/${mcp}
    if [ $? -ne 0 ]; then
        echo "Failed to pause mcp"
        exit 1
    fi

    ret=$(oc get machineconfigpools ${mcp} -ojson | jq -r '.spec.paused')
    if [[ "${ret}" != "true" ]]; then
        echo >&2 "${mcp} pool failed to pause, exiting" && exit 1
    fi
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# check all actual mcp, if any of them unknown then break the job.
echo "Checking if there are unexpected mcps..."
expected_mcp=("master" "worker")
declare -a arr=()
mapfile -t arr < <(echo "${MCO_CONF_DAY2_CUSTOM_MCP}"|  jq -r '.[].mcp_name')
expected_mcp+=("${arr[*]}")
echo -e "Expected mcps: ${expected_mcp[*]} \n"

actual_mcp=$(oc get mcp --output jsonpath="{.items[*].metadata.name}")
IFS=" " read -r -a actual_mcp_arr <<<"$actual_mcp"
echo -e "Observed mcps: ${actual_mcp_arr[*]}\n"
for mcp in "${actual_mcp_arr[@]}";
do
    if [[ ! " ${expected_mcp[*]} " =~ [[:space:]]${mcp}[[:space:]] ]]; then
        echo "Unknown mcp found: ${mcp}"
        exit 1
    fi
done
echo -e "Finished checking unexpected mcps, all mcps are expected.\n"

# pause all custom mcp
IFS=" " read -r -a arr <<<"$PAUSED_MCP_NAME"
for mcp in "${arr[@]}";
do
    pause $mcp
done