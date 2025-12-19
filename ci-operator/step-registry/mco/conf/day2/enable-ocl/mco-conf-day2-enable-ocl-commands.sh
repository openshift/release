#!/bin/bash

set -e
set -u
set -o pipefail

# v1 is used in clusters 4.19+
MOSC_V1_API_VERSION="v1"
# vialpha is used in clusters 4.18-
MOSC_V1ALPHA_API_VERSION="v1alpha1"

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
    echo 'Current scenario:'
    run_command "oc -n openshift-machine-config-operator get mcp,nodes,machineosconfig,machineosbuild"
    echo ''
    echo '####################################################'
    echo '####################################################'
    echo ''
    echo 'All pods:'
    run_command "oc get pods -n openshift-machine-config-operator"
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
    run_command "oc logs -l machineconfiguration.openshift.io/on-cluster-layering -n openshift-machine-config-operator"
    exit 255
}

if  [[ -z "$MCO_CONF_DAY2_OCL_POOLS" ]]; then
    echo "OCL is not configured in any MachineConfigPool, skip it."
    exit 0
fi

set_proxy

# Determine the registry to use for OCL builds (use mirror registry for disconnected clusters)
if [ -f "${SHARED_DIR}/mirror_registry_url" ]; then
    MIRROR_REGISTRY=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
    OCL_REGISTRY="${MIRROR_REGISTRY}/mcoqe/layering"
    echo "Using mirror registry for OCL builds: ${OCL_REGISTRY}"
else
    OCL_REGISTRY="quay.io/mcoqe/layering"
    echo "Using quay.io for OCL builds: ${OCL_REGISTRY}"
fi

IFS=" " read -r -a mcp_arr <<<"$MCO_CONF_DAY2_OCL_POOLS"
# Currently only v1 or v1alpha are provided and they are mutually exclusive. If anything  changes we want this step to fail, that's why we get [*] in the jsonpath
# If more than one api is provided we need to analyse if it is right or not, and if necessary adapt this code
MOSC_API_VERSION=$(oc get crd -oyaml machineosconfigs.machineconfiguration.openshift.io -ojsonpath='{.spec.versions[*].name}')

echo ""
echo "Using MOSC API: $MOSC_API_VERSION"

if [ "$MOSC_API_VERSION" == "$MOSC_V1ALPHA_API_VERSION" ]; then
    for custom_mcp_name in "${mcp_arr[@]}"; do
        # Define MOSC name with custom pool parameter
        MOSC_NAME="$custom_mcp_name"
        echo ""
        echo "Enable OCL in pool $custom_mcp_name"
    
        oc create -f - << EOF
apiVersion: machineconfiguration.openshift.io/v1alpha1
kind: MachineOSConfig
metadata:
  name: $MOSC_NAME
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
    renderedImagePushspec: "${OCL_REGISTRY}:ocl-$custom_mcp_name"
    containerFile:
        - content: |-
            LABEL maintainer="mco-qe-team" quay.expires-after=$MCO_CONF_DAY2_OCL_IMG_EXPIRATION_TIME
EOF

        oc get machineosconfig -oyaml "$MOSC_NAME"

    done

elif [ "$MOSC_API_VERSION" == "$MOSC_V1_API_VERSION" ] ; then
    for custom_mcp_name in "${mcp_arr[@]}"; do
        # Define MOSC name with custom pool parameter
        MOSC_NAME="$custom_mcp_name"
        echo ""
        echo "Enable OCL in pool $custom_mcp_name"
    
        oc create -f - << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineOSConfig
metadata:
  name: $MOSC_NAME
spec:
  machineConfigPool:
    name: $custom_mcp_name
  imageBuilder:
    imageBuilderType: Job
  # baseImagePullSecret is optional, but we need to provide it or the test cases that need to use an empty pull-secret will fail because OCL will not be able to know how to pull the base image
  baseImagePullSecret:
    name: $(oc get secret -n openshift-config pull-secret -o json | jq "del(.metadata.namespace, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.name)" | jq '.metadata.name="pull-copy"' | oc -n openshift-machine-config-operator create -f - &> /dev/null; echo -n "pull-copy")
  renderedImagePushSecret:
    name: $(oc get secret -n openshift-config pull-secret -o json | jq "del(.metadata.namespace, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.name)" | jq '.metadata.name="pull-copy"' | oc -n openshift-machine-config-operator create -f - &> /dev/null; echo -n "pull-copy")
  renderedImagePushSpec: "${OCL_REGISTRY}:ocl-$custom_mcp_name"
  containerFile:
      - content: |-
          LABEL maintainer="mco-qe-team" quay.expires-after=$MCO_CONF_DAY2_OCL_IMG_EXPIRATION_TIME
EOF

        oc get machineosconfig -oyaml "$MOSC_NAME"

    done

else
    echo "Suported MOSC API versions [$MOSC_V1ALPHA_API_VERSION, $MOSC_V1ALPHA_API_VERSION] MOSCO Unexpected MOSC API version: $MOSC_API_VERSION"
    debug_and_exit
fi

for custom_mcp_name in "${mcp_arr[@]}"; do
    echo ""
    echo "Wait for the $custom_mcp_name MCP to start building the OCL image"
    MOSC_NAME="$custom_mcp_name"
    echo "Waiting for a MOSB resource to be created for mosc $MOSC_NAME"
    if ! run_command "oc wait --for=jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/current-machine-os-build}' machineosconfig $MOSC_NAME --timeout=300s"
    then
        echo "ERROR. The $MOSC_NAME MOSC resource was not updated with a new MOSB annotation"
        debug_and_exit
    fi

    machine_os_build_name=$(oc get machineosconfig "$MOSC_NAME" -ojsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/current-machine-os-build}')
    echo "Waiting for a $machine_os_build_name MOSB to exist"
    if ! run_command "oc wait --for=create machineosbuild $machine_os_build_name --timeout=300s"
    then
        echo "ERROR. The $machine_os_build_name MOSB resource was not created"
        debug_and_exit
    fi

    echo "Waiting for $machine_os_build_name MOSB to start building"
    if ! run_command "oc wait --for=condition=Building  machineosbuild $machine_os_build_name --timeout=300s"
    then
        echo "ERROR. The $machine_os_build_name MOSB resource didn't start building the image"
        debug_and_exit
    fi
done

for custom_mcp_name in "${mcp_arr[@]}"; do
    echo ""
    echo "Wait for the $custom_mcp_name MCP to finish building the OCL image"
    MOSC_NAME="$custom_mcp_name"

    machine_os_build_name=$(oc get machineosconfig "$MOSC_NAME" -ojsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/current-machine-os-build}')

    echo "Waiting for $machine_os_build_name MOSB to succeed"
    if ! run_command "oc wait --for=condition=Succeeded  machineosbuild $machine_os_build_name --timeout=600s"
    then
        echo "ERROR. The $machine_os_build_name MOSB resource failed to build the image"
        debug_and_exit
    fi
done

for custom_mcp_name in "${mcp_arr[@]}"; do
    echo ""
    echo "Waiting for $custom_mcp_name MachineConfigPool to start updating..."
    if ! run_command "oc wait mcp $custom_mcp_name --for='condition=UPDATING=True' --timeout=600s"
    then
        echo "ERROR. The $custom_mcp_name MCP didn't get the UPDATING=True condition"
        debug_and_exit
    fi
done

for custom_mcp_name in "${mcp_arr[@]}"; do
    echo ""
    echo "Waiting for $custom_mcp_name MachineConfigPool to finish updating..."
    if ! run_command "oc wait mcp $custom_mcp_name --for='condition=UPDATED=True' --timeout=45m"
    then
        echo "ERROR. The $custom_mcp_name MCP didn't get the UPDATED=True condition"
        debug_and_exit
    fi
done
