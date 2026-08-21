#!/bin/bash

set -e
set -u
set -o pipefail

function set_proxy () {
    if [ -s "${SHARED_DIR}/proxy-conf.sh" ]; then
        echo "Setting the proxy ${SHARED_DIR}/proxy-conf.sh"
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings"
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# waiting for mcp become a given status
function wait_for_config_to_be_applied() {
    local mcp_name="$1"
    local expected_machine_count="$2"
    local out MACHINECOUNT 

    echo "Waiting for $mcp_name MachineConfigPool to finish updating..."
    oc wait mcp "$mcp_name" --for='condition=UPDATED=True' --timeout=300s 2>/dev/null
    
    out="$(oc get machineconfigpools ${mcp_name} --no-headers)"
    echo $out
    MACHINECOUNT="$(echo "${out}" | awk '{print $6}')"

    if [[ "${MACHINECOUNT}" != "${expected_machine_count}" ]]; then
        run_command "oc get machineconfigpools"
        run_command "oc get nodes"
        echo "MCP ${mcp_name} is not ready for next step, exit..." && exit 1
    fi
}

function remove_custom_mcp() {
    local mcp_name="$1" mcp_node_label label
    # mcp_node_label will be like: node-role.kubernetes.io/worker=,lable2=true,lable3=ota
    mcp_node_label=$(oc get mcp ${mcp_name} -ojson | jq -r '.spec.nodeSelector.matchLabels | to_entries | map([.key, .value] | join("=")) | join(",")')
    local -a matched_nodes_array=()
    local -a label_array=()

    echo "Removing customer worker node label from mcp ${mcp_name}"
    read -a matched_nodes_array <<< "$(oc get nodes -l ${mcp_node_label} -ojsonpath="{.items[:].metadata.name}")"
    echo -e "Matched nodes with label ${mcp_node_label}: ${matched_nodes_array[*]}\n"

    if [[ ${#matched_nodes_array[@]} == 0 ]]; then
        echo "No matched nodes!"
        return 0
    fi

    local out WORKER_MACHINECOUNT EXPECTED_WORKER_MACHINECOUNT node
    local -a arrLabel=()
    echo "MCP status before removing custom mcp label:"
    run_command "oc get machineconfigpools"

    out="$(oc get machineconfigpools worker --no-headers)"
    WORKER_MACHINECOUNT="$(echo "${out}" | awk '{print $6}')"
    printf "\n"

    IFS=',' read -r -a label_array <<< "${mcp_node_label}"
    for node in "${matched_nodes_array[@]}"; do
        for label in "${label_array[@]}"; do
            IFS="=" read -r -a arrLabel <<<"$label"
            run_command "oc label node ${node} ${arrLabel[0]}-"
        done
    done

    echo -e "\nWaiting for default worker MachineConfigPool to start updating..."
    oc wait mcp worker --for='condition=UPDATING=True' --timeout=300s &>/dev/null
    # after removing the label of worker node, the customer mcp's machine count will be changed to 0
    wait_for_config_to_be_applied ${mcp_name} "0"

    echo -e "\nCheck the default worker mcp status after removing customer mcp label:"
    EXPECTED_WORKER_MACHINECOUNT=$(( ${#matched_nodes_array[@]} + ${WORKER_MACHINECOUNT} ))
    wait_for_config_to_be_applied "worker" "${EXPECTED_WORKER_MACHINECOUNT}"

    printf "\n"
    run_command "oc delete mcp ${mcp_name}"
}

if  [[ -z "$MCO_CONF_DAY2_CUSTOM_MCP_TO_BE_DELETED" ]]; then
  echo "No custome mcp need to be deleted, skip it."
  exit 0
fi
set_proxy
IFS=" " read -r -a mcp_arr <<<"$MCO_CONF_DAY2_CUSTOM_MCP_TO_BE_DELETED"
for custom_mcp_name in "${mcp_arr[@]}"; do
    if [[ "${custom_mcp_name}" != "worker" ]]; then
        remove_custom_mcp "$custom_mcp_name"
    else
        echo "Worker mcp could not be removed, continue to next mcp"
    fi
done