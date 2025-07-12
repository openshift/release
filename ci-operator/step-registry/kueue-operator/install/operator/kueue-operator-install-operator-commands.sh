#!/bin/bash

set -e
set -u
set -o pipefail

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

function wait_for_state() {
    local object="$1"
    local state="$2"
    local timeout="$3"
    local namespace="${4:-}"
    local selector="${5:-}"

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to exist..."
    for _ in {1..30}; do
        oc get ${object} --selector="${selector}" -n=${namespace} |& grep -ivE "(no resources found|not found)" && break || sleep 5
    done

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to become '${state}'..."
    oc wait --for=${state} --timeout=${timeout} ${object} --selector="${selector}" -n="${namespace}"
    return $?
}

function install_operator_bundle () {
    echo "Patching CSV to use mirrored operator image..."
    
    # Source environment variables from previous steps
    if test -s "${SHARED_DIR}/env" ; then
        echo "Sourcing environment variables from previous steps..."
        source "${SHARED_DIR}/env"
    fi
    
    if [[ -z "${OPERATOR_IMAGE:-}" ]]; then
        echo "ERROR: OPERATOR_IMAGE not set by previous steps"
        exit 1
    fi
    
    echo "Using OPERATOR_IMAGE: ${OPERATOR_IMAGE}"
    
    # Wait for the operator deployment to be ready (installed by run-sdk step)
    if wait_for_state "deployment/openshift-kueue-operator" "condition=Available" "5m" "openshift-kueue-operator"; then
        echo "Kueue operator is ready"
    else
        echo "Timed out waiting for kueue operator. Dumping resources for debugging..."
        run_command "oc get pod -n openshift-kueue-operator"
        run_command "oc get event -n openshift-kueue-operator"
        exit 1
    fi

    # Wait for Kueue CRD to be available
    if wait_for_state "crd/kueues.kueue.openshift.io" "condition=Established" "2m" "" ""; then
        echo "Kueue CRD is established"
    else
        echo "Timed out waiting for Kueue CRD. Dumping resources for debugging..."
        run_command "oc get crd | grep kueue"
        exit 1
    fi

    # Patch the CSV to use the mirrored operator image
    echo "Patching CSV to use mirrored operator image..."
    CSV=$(oc get csv -n openshift-kueue-operator -o jsonpath='{.items[0].metadata.name}')
    if [[ -n "$CSV" ]]; then
        echo "Patching CSV $CSV to use mirrored operator image..."
        oc patch csv -n openshift-kueue-operator $CSV --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"$OPERATOR_IMAGE\"}]"
        echo "CSV patched successfully"
    else
        echo "WARNING: No CSV found to patch"
        exit 1
    fi
}

timestamp
set_proxy
install_operator_bundle

echo "[$(timestamp)] Succeeded in installing the kueue Operator for Red Hat OpenShift!"
