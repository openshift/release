#!/bin/bash

set -e
set -u
set -o pipefail

if  [ "$MCO_CONF_DAY2_CUSTOM_MCP_NAME" == "" ]; then
  echo "This installation does not need to create any custom MachineConfigPool"
  exit 0
fi


function set_proxy () {
    if [ -s "${SHARED_DIR}/proxy-conf.sh" ]; then
        echo "Setting the proxy ${SHARED_DIR}/proxy-conf.sh"
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings"
    fi
}

function validate_params() {
  NUM_WORKERS=$(oc get nodes -l "$MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL" -oname | wc -l)

  if [ "$MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES" != "" ] && (( MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES > NUM_WORKERS  )) ; then
    echo "ERROR: We are trying to add $MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES to our custom pool, but there are only $NUM_WORKERS nodes available with label $MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL"
    exit 255
  fi

  if [ "$MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES" != "" ] && (( MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES < 0  )) ; then
    echo "ERROR: Refuse to create a custom MCP with a negative number of nodes."
    exit 255
  fi
}

function create_custom_mcp() {
  local MCP_NAME=$1
  local MCP_NUM_NODES=$2
  local MCP_LABEL=$3

  echo "Creating custom MachineConfigPool with name $MCP_NAME from label $MCP_LABEL"

  oc create -f - << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: $MCP_NAME
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,$MCP_NAME]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/$MCP_NAME: ""
EOF

  if [ "$MCP_NUM_NODES" == "0" ]; then
    echo "It has been requested to add 0 nodes to the pool. No node will be added to the custom MachineConfigPool."
  else
    if [ "$MCP_NUM_NODES" == "" ]; then
	echo "MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES variable is empty. All nodes matching the '$MCP_LABEL' label will be added to the custom pool"
    fi

    echo "Labeling $MCP_NUM_NODES worker nodes in order to add them to the new custom MCP"
    # shellcheck disable=SC2046
    oc label node $(oc get nodes -l "$MCP_LABEL" -ojsonpath="{.items[:$MCP_NUM_NODES].metadata.name}") node-role.kubernetes.io/"$MCO_CONF_DAY2_CUSTOM_MCP_NAME"=
  fi
}

function wait_for_config_to_be_applied() {
  local MCP_NAME=$1
  local MCP_NUM_NODES=$2
  local MCP_TIMEOUT=$3

  if [ "$MCP_NUM_NODES" != "0" ]; then
    echo "Waiting for $MCP_NAME MachineConfigPool to start updating..."
    oc wait mcp "$MCP_NAME" --for='condition=UPDATING=True' --timeout=300s &>/dev/null
  fi

  echo "Waiting for $MCP_NAME MachineConfigPool to finish updating..."
  oc wait mcp "$MCP_NAME" --for='condition=UPDATED=True' --timeout="$MCP_TIMEOUT" 2>/dev/null

}


validate_params
set_proxy
create_custom_mcp "$MCO_CONF_DAY2_CUSTOM_MCP_NAME" "$MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES" "$MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL"
wait_for_config_to_be_applied "$MCO_CONF_DAY2_CUSTOM_MCP_NAME" "$MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES" "$MCO_CONF_DAY2_CUSTOM_MCP_TIMEOUT"

oc get mcp
