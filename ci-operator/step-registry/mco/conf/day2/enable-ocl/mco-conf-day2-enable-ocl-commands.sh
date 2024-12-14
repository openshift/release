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

function debug_and_exit() {
    echo 'An error happened. Debuging before exiting...'
    echo ''
    echo '####################################################'
    echo '####################################################'
    echo ''
    echo 'All pods:'
    run_command "oc get pods"
    echo ''
    echo '####################################################'
    echo '####################################################'
    echo ''
    echo 'All MOSCs'
    run_command "oc get machineosconfig -oyaml"
    echo ''
    echo '####################################################'
    echo '####################################################'
    echo ''
    echo 'All MOSBs'
    run_command "oc get machineosbuild -oyaml"
    echo ''
    echo '####################################################'
    echo '####################################################'
    echo ''
    echo 'Builder pods logs'
    run_command "oc logs pods -l machineconfiguration.openshift.io/on-cluster-layering"
    exit 255
}

if  [[ -z "$MCO_CONF_DAY2_OCL_POOLS" ]]; then
    echo "OCL is not configured in any MachineConfigPool, skip it."
    exit 0
fi

set_proxy

IFS=" " read -r -a mcp_arr <<<"$MCO_CONF_DAY2_OCL_POOLS"
for custom_mcp_name in "${mcp_arr[@]}"; do

    echo "Enable OCL in pool $custom_mcp_name"

   oc create -f - << EOF
apiVersion: machineconfiguration.openshift.io/v1alpha1
kind: MachineOSConfig
metadata:
  name: mosc-$custom_mcp_name
spec:
  machineConfigPool:
    name: $custom_mcp_name
  buildOutputs:
    currentImagePullSecret:
      name: $(oc get secret -n openshift-config pull-secret -o json | jq "del(.metadata.namespace, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.name)" | jq '.metadata.name="pull-copy"' | oc -n openshift-machine-config-operator create -f - &> /dev/null; echo -n "pull-copy")
  buildInputs:
    imageBuilder:
      imageBuilderType: PodImageBuilder
    baseImagePullSecret:
      name: $(oc get secret -n openshift-config pull-secret -o json | jq "del(.metadata.namespace, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.name)" | jq '.metadata.name="pull-copy"' | oc -n openshift-machine-config-operator create -f - &> /dev/null; echo -n "pull-copy")
    renderedImagePushSecret:
      name: $(oc get secret -n openshift-config pull-secret -o json | jq "del(.metadata.namespace, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.name)" | jq '.metadata.name="pull-copy"' | oc -n openshift-machine-config-operator create -f - &> /dev/null; echo -n "pull-copy")
    renderedImagePushspec: "quay.io/mcoqe/layering:ocl-$custom_mcp_name"
    containerFile:
        - content: |-
            LABEL maintainer="mco-qe-team" quay.expires-after=$MCO_CONF_DAY2_OCL_IMG_EXPIRATION_TIME
EOF

    oc get machineosconfig -oyaml "mosc-$custom_mcp_name"

done

for custom_mcp_name in "${mcp_arr[@]}"; do
    echo "Waiting for $custom_mcp_name MachineConfigPool to start updating..."
    if ! run_command "oc wait mcp $custom_mcp_name --for='condition=UPDATING=True' --timeout=300s &>/dev/null"
    then
        debug_and_exit
    fi
done


for custom_mcp_name in "${mcp_arr[@]}"; do
    echo "Wait for the $custom_mcp_name MCP to start building the OCL build"
    machine_os_build_name="$custom_mcp_name-$(oc get machineconfigpool "$custom_mcp_name"  -ojsonpath='{.spec.configuration.name}')-builder"
    if ! run_command "oc wait --for=condition=Building  machineosbuild $machine_os_build_name --timeout=300s &>/dev/null"
    then
        debug_and_exit
    fi
done

for custom_mcp_name in "${mcp_arr[@]}"; do
    echo "Wait for the $custom_mcp_name MCP OCL build to succeed"
    machine_os_build_name="$custom_mcp_name-$(oc get machineconfigpool "$custom_mcp_name"  -ojsonpath='{.spec.configuration.name}')-builder"
    if ! run_command "oc wait --for=condition=Succeeded  machineosbuild $machine_os_build_name --timeout=600s &>/dev/null"
    then
        debug_and_exit
    fi
done

for custom_mcp_name in "${mcp_arr[@]}"; do
    echo "Waiting for $custom_mcp_name MachineConfigPool to finish updating..."
    if ! run_command "oc wait mcp $custom_mcp_name --for='condition=UPDATED=True' --timeout=45m 2>/dev/null"
    then
        debug_and_exit
    fi
done
