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

function remove_item_from_array() {
    local del="$1"
    shift
    local arr=("$@")
    arr=("${arr[@]/$del}")
    echo "${arr[@]}"
}

function create_custom_mcp() {
  local mcp_name="$1"
  local mcp_node_num="$2"
  local mcp_node_label="$3"
  local node="" expected_mcp_node_num="${mcp_node_num}"
  local -a matched_nodes_array=()
  local -a target_nodes_array=()

  echo "Creating custom MachineConfigPool with name ${mcp_name} with ${mcp_node_num} nodes labeld with ${mcp_node_label}"

  read -a matched_nodes_array <<< "$(oc get nodes -l ${mcp_node_label} -ojsonpath="{.items[:].metadata.name}")"
  echo "Matched nodes with ${mcp_node_label} label: ${matched_nodes_array[*]}"
  echo "Available free nodes in the cluser: ${ALL_NODES_LIST[*]}"

  if [[ ${#matched_nodes_array[@]} == 0 ]]; then
    echo "No matched nodes!"
    return 255
  fi

  for node in "${matched_nodes_array[@]}"; do
    #shellcheck disable=SC2076
    if [[ " ${ALL_NODES_LIST[*]} " =~ " ${node} " ]]; then
      target_nodes_array+=("${node}")
      read -a ALL_NODES_LIST <<< "$(remove_item_from_array "${node}" "${ALL_NODES_LIST[@]}")"
      mcp_node_num=$((mcp_node_num - 1))
    fi
    if (( $mcp_node_num == 0 )); then
        break
    fi
  done

  if [[ "${expected_mcp_node_num}" != "${#target_nodes_array[@]}" ]]; then
    echo "Found ${#target_nodes_array[@]} matched available free nodes (${target_nodes_array[*]}), but expecting ${expected_mcp_node_num} nodes"
    return 255
  fi

  oc create -f - << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: $mcp_name
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,$mcp_name]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/$mcp_name: ""
EOF

  run_command "oc label node ${target_nodes_array[*]} node-role.kubernetes.io/$mcp_name="

  echo "Waiting for $mcp_name MachineConfigPool to start updating..."
  oc wait mcp "$mcp_name" --for='condition=UPDATING=True' --timeout=300s &>/dev/null
}

function wait_for_config_to_be_applied() {
  local mcp_name="$1"
  local mcp_timeout="$2"

  echo "Waiting for $mcp_name MachineConfigPool to finish updating..."
  oc wait mcp "$mcp_name" --for='condition=UPDATED=True' --timeout="$mcp_timeout" 2>/dev/null
}

if  [[ -z "$MCO_CONF_DAY2_CUSTOM_MCP" ]]; then
  echo "This installation does not need to create any custom MachineConfigPool"
  exit 0
fi
set_proxy
read -a ALL_NODES_LIST <<< "$(oc get nodes -ojsonpath="{.items[:].metadata.name}")"
custom_mcp_num=$(echo "${MCO_CONF_DAY2_CUSTOM_MCP}" | jq -r ". | length")
last_mcp_index=$((custom_mcp_num - 1))
for index in $(seq 0 ${last_mcp_index}); do
    custom_mcp_name=$(echo "${MCO_CONF_DAY2_CUSTOM_MCP}" | jq -r ".[$index].mcp_name")
    if [[ -z "$custom_mcp_name" ]]; then
        echo "No mcp_name input"
        exit 255
    fi
    custom_mcp_node_num=$(echo "${MCO_CONF_DAY2_CUSTOM_MCP}" | jq -r ".[$index].mcp_node_num")
    if [[ -z "$custom_mcp_node_num" ]]; then
        echo "No mcp_node_num input, set it to '1' by default"
        custom_mcp_node_num="1"
    fi
    custom_mcp_node_label=$(echo "${MCO_CONF_DAY2_CUSTOM_MCP}" | jq -r ".[$index].mcp_node_label")
    if [[ -z "$custom_mcp_node_label" ]]; then
        echo "No mcp_node_num input, set it to 'node-role.kubernetes.io/worker' by default"
        custom_mcp_node_label="node-role.kubernetes.io/worker="
    fi
    create_custom_mcp "$custom_mcp_name" "$custom_mcp_node_num" "$custom_mcp_node_label"
    wait_for_config_to_be_applied "$custom_mcp_name" "$MCO_CONF_DAY2_CUSTOM_MCP_TIMEOUT"
done
oc get mcp
