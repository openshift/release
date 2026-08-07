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

CLUSTER_PACKAGE_NAME=""
OPERATOR_NAMESPACE=""

if [[ -n "${SHARED_DIR:-}" ]]; then
    CLUSTER_PACKAGE_NAME=$(cat "${SHARED_DIR}/operator-e2e-clusterpackage" 2>/dev/null || true)
    OPERATOR_NAMESPACE=$(cat "${SHARED_DIR}/operator-e2e-namespace" 2>/dev/null || true)
fi

# Collect operator logs as artifacts for debugging
if [[ -n "${OPERATOR_NAMESPACE}" && -n "${ARTIFACT_DIR:-}" ]]; then
    log "Collecting operator logs from ${OPERATOR_NAMESPACE}"
    for deploy in $(oc get deployment -n "${OPERATOR_NAMESPACE}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true); do
        oc logs "deployment/${deploy}" -n "${OPERATOR_NAMESPACE}" --all-containers --tail=500 \
            > "${ARTIFACT_DIR}/${deploy}-logs.txt" 2>&1 || true
        log "  Saved ${deploy} logs"
    done
    oc get events -n "${OPERATOR_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${ARTIFACT_DIR}/operator-namespace-events.txt" 2>&1 || true
fi

if [[ -z "${CLUSTER_PACKAGE_NAME}" ]]; then
    log "No ClusterPackage to clean up"
    exit 0
fi

log "Cleaning up test operator resources"

CP_DELETED=false
if oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" &>/dev/null; then
    log "Deleting ClusterPackage ${CLUSTER_PACKAGE_NAME}"
    oc delete clusterpackage "${CLUSTER_PACKAGE_NAME}" --timeout=120s || true
    for _i in $(seq 1 24); do
        RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
        if [[ -z "${RESULT}" ]]; then
            CP_DELETED=true
            break
        fi
        sleep 5
    done
else
    CP_DELETED=true
fi

# Clear CRD ownerReferences left by the e2e ClusterPackage so the
# production ClusterPackage can re-adopt them. Without this, PKO
# refuses adoption with "not owned by previous revision".
# Only proceed if the ClusterPackage was confirmed deleted.
if [[ "${CP_DELETED}" == "true" && -n "${OPERATOR_CRDS:-}" && -n "${OPERATOR_NAME:-}" ]]; then
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        if oc get crd "${crd}" &>/dev/null; then
            INSTANCE=$(oc get crd "${crd}" -o jsonpath='{.metadata.labels.package-operator\.run/instance}' 2>/dev/null || true)
            OWNER_COS=$(oc get crd "${crd}" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
            if [[ "${INSTANCE}" == "${CLUSTER_PACKAGE_NAME}" && -n "${OWNER_COS}" ]]; then
                # Confirm the owner COS is actually gone (not just an API error)
                COS_CHECK=$(oc get "clusterobjectset/${OWNER_COS}" --ignore-not-found -o name 2>&1) || true
                if [[ -z "${COS_CHECK}" ]]; then
                    log "Clearing stale e2e ownership on CRD ${crd} (owner ${OWNER_COS} gone)"
                    oc patch crd "${crd}" --type merge -p '{"metadata":{"ownerReferences":[],"labels":{"package-operator.run/instance":"'"${OPERATOR_NAME}"'"}}}' 2>/dev/null || true
                fi
            fi
        fi
    done
fi

log "Cleanup complete"
