#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Label the first harf of worker nodes with mcpfoo, then rest part of worker node with mcpbar
function label_node() {
    echo "Label worker node..."
    local worker worker_list worker_size
    worker=$(oc get -l 'node-role.kubernetes.io/master!=' -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' nodes)
    worker_list=(${worker})

    worker_size=${#worker_list[@]}
    if [[ $worker_size -lt 2 ]]; then 
        echo 'There are no enough worker nodes for canary upgrade, requires at lease 2 worker nodes'; 
        exist 1
    fi

    for i in "${!worker_list[@]}"; do
        node=${worker_list[i]}
        if [[ $i -le $worker_size/2 ]]; then
            run_command "oc label node ${node} node-role.kubernetes.io/mcpfoo="
        else
            run_command "oc label node ${node} node-role.kubernetes.io/mcpbar="
        fi
    done
}

# creating mcp with a given worker node label
function create_mcp() {
    echo "Creating mcp..."
    local label=${1}

    oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: ${label}
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,${label}]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/${label}: ""
EOF
    if [ $? -ne 0 ]; then
        echo "Creating mcp with label ${label} failed"
        exit 1
    fi
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

label_node

create_mcp "mcpfoo"
create_mcp "mcpbar"
