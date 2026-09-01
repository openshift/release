#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

PACKAGE_NAME=""
OPERATOR_NAMESPACE=""

if [[ -n "${SHARED_DIR:-}" ]]; then
    PACKAGE_NAME=$(cat "${SHARED_DIR}/operator-e2e-clusterpackage" 2>/dev/null || true)
    OPERATOR_NAMESPACE=$(cat "${SHARED_DIR}/operator-e2e-namespace" 2>/dev/null || true)
fi

if [[ -z "${OPERATOR_NAMESPACE}" ]]; then
    OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-validation-webhook}"
fi

# Collect operator logs as artifacts before cleanup
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    log "Collecting operator logs from ${OPERATOR_NAMESPACE}"
    for deploy in $(oc get deployment -n "${OPERATOR_NAMESPACE}" --no-headers \
            -o custom-columns=':metadata.name' 2>/dev/null || true); do
        oc logs "deployment/${deploy}" -n "${OPERATOR_NAMESPACE}" --all-containers --tail=500 \
            > "${ARTIFACT_DIR}/${deploy}-logs.txt" 2>&1 || true
        log "  Saved ${deploy} logs"
    done
    oc get events -n "${OPERATOR_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${ARTIFACT_DIR}/operator-namespace-events.txt" 2>&1 || true
fi

if [[ -z "${PACKAGE_NAME}" ]]; then
    log "No Package to clean up"
    exit 0
fi

log "Cleaning up MCVW test Package ${PACKAGE_NAME} in ${OPERATOR_NAMESPACE}"

if oc get package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
    oc delete package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=120s || true
    for _i in $(seq 1 24); do
        RESULT=$(oc get package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" \
            --ignore-not-found -o name 2>&1) || true
        if [[ -z "${RESULT}" ]]; then
            break
        fi
        sleep 5
    done
    # Force-remove finalizers if still stuck
    RESULT=$(oc get package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" \
        --ignore-not-found -o name 2>&1) || true
    if [[ -n "${RESULT}" ]]; then
        log "WARNING: Package still exists, removing finalizers"
        oc patch package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" \
            --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    fi
fi

log "Cleanup complete"
