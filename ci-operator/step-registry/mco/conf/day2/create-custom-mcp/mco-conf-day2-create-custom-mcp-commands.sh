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
  local MCP_NUM_NODES=$1
  local MCP_LABEL=$2

  # shellcheck disable=SC2086
  NUM_WORKERS=$(oc get nodes -l $MCP_LABEL -oname | wc -l)

  if [ "$MCP_NUM_NODES" != "" ] && (( MCP_NUM_NODES > NUM_WORKERS  )) ; then
    echo "ERROR: We are trying to add $MCP_NUM_NODES to our custom pool, but there are only $NUM_WORKERS nodes available with label $MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL"
    exit 255
  fi
}

function create_custom_mcp() {
  local MCP_NAME=$1
  local MCP_NUM_NODES=$2
  local MCP_LABEL=$3


  echo "MCP_NAME=$MCP_NAME"
  echo "MCP_LABEL=$MCP_LABEL"
  echo "MCP_NUM_NODES=$MCP_NUM_NODES"

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
    return
  fi

  # If <0 is provided, we include all available nodes in this pool
  if (( MCP_NUM_NODES < 0 ))
  then
    echo "A negative number of nodes was provided. We set an empty variable so that all nodes are added to the pool"
    MCP_NUM_NODES=""
  fi

  [ -z "$MCP_NUM_NODES" ] \
    && echo "MCP_NUM_NODES variable is empty. All nodes matching the '$MCP_LABEL' label will be added to the custom pool" \
    || echo "Labeling $MCP_NUM_NODES worker nodes in order to add them to the new custom MCP"

  # shellcheck disable=SC2046
  oc label node $(oc get nodes -l "$MCP_LABEL" -ojsonpath="{.items[:$MCP_NUM_NODES].metadata.name}") node-role.kubernetes.io/"$MCP_NAME"=
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


set_proxy

echo "MCO_CONF_DAY2_CUSTOM_MCP_NAME $MCO_CONF_DAY2_CUSTOM_MCP_NAME"
read -r -a ARR_CUSTOM_MCP_NAME <<< "$MCO_CONF_DAY2_CUSTOM_MCP_NAME"

echo "MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL $MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL"
read -r -a ARR_CUSTOM_MCP_FROM_LABEL <<< "$MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL"
LEN_CUSTOM_MCP_FROM_LABEL=${#ARR_CUSTOM_MCP_FROM_LABEL[@]}
echo "LEN_CUSTOM_MCP_FROM_LABEL $LEN_CUSTOM_MCP_FROM_LABEL"

echo "MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES $MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES"
read -r -a ARR_CUSTOM_MCP_NUM_NODES <<< "$MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES"
LEN_CUSTOM_MCP_NUM_NODES=${#ARR_CUSTOM_MCP_NUM_NODES[@]}
echo "LEN_CUSTOM_MCP_NUM_NODES $LEN_CUSTOM_MCP_NUM_NODES"


echo "MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_FROM_LABEL $MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_FROM_LABEL"
echo "MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_NUM_NODES $MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_NUM_NODES"

# We cannot add the same node to more than one MCP, so we build an exclusion label
# so that the nodes that have been added to previous custom pools are not candidates for the new pools
# We would use a label like this: actualLabel + exclusionLabel
#
EXCLUSION_LABEL=""
for POOL_NAME in "${ARR_CUSTOM_MCP_NAME[@]}"
do
  EXCLUSION_LABEL="$EXCLUSION_LABEL,!node-role.kubernetes.io/$POOL_NAME"
done

echo "EXCLUSION_LABEL $EXCLUSION_LABEL"

INDEX=0
for POOL_NAME in "${ARR_CUSTOM_MCP_NAME[@]}"
do 

  if (( INDEX > LEN_CUSTOM_MCP_FROM_LABEL-1  ));
  then
    POOL_LABEL="${MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_FROM_LABEL}"
  else 
    POOL_LABEL="${ARR_CUSTOM_MCP_FROM_LABEL[$INDEX]}"
  fi

  if (( INDEX > LEN_CUSTOM_MCP_NUM_NODES-1  ));
  then
    POOL_NUM_NODES="${MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_NUM_NODES}"
  else 
    POOL_NUM_NODES="${ARR_CUSTOM_MCP_NUM_NODES[$INDEX]}"
  fi

  POOL_FULL_LABEL="$POOL_LABEL$EXCLUSION_LABEL"

  echo ' ------ '
  echo "$POOL_NAME"
  echo "$POOL_NUM_NODES"
  echo "$POOL_LABEL"
  echo "$POOL_FULL_LABEL"
  echo ' ------ '


  validate_params "$POOL_NUM_NODES" "$POOL_FULL_LABEL"
  create_custom_mcp "$POOL_NAME" "$POOL_NUM_NODES" "$POOL_FULL_LABEL"
  wait_for_config_to_be_applied "$POOL_NAME" "$POOL_NUM_NODES" "$MCO_CONF_DAY2_CUSTOM_MCP_TIMEOUT"

  (( INDEX=INDEX+1 ))
done


oc get mcp
