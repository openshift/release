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

MODE=""
PACKAGE_NAME=""
OPERATOR_NAMESPACE=""

if [[ -n "${SHARED_DIR:-}" ]]; then
    MODE=$(cat "${SHARED_DIR}/operator-e2e-mode" 2>/dev/null || true)
    PACKAGE_NAME=$(cat "${SHARED_DIR}/operator-e2e-clusterpackage" 2>/dev/null || true)
    OPERATOR_NAMESPACE=$(cat "${SHARED_DIR}/operator-e2e-namespace" 2>/dev/null || true)
fi

if [[ -z "${OPERATOR_NAMESPACE}" ]]; then
    OPERATOR_NAMESPACE="openshift-validation-webhook"
fi

OPERATOR_DEPLOYMENT_NAME="${OPERATOR_DEPLOYMENT_NAME:-validation-webhook}"

# Collect operator logs as artifacts before cleanup
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    log "Collecting operator logs from ${OPERATOR_NAMESPACE}"
    for deploy in $(oc get deployment -n "${OPERATOR_NAMESPACE}" --no-headers \
            -o custom-columns=':metadata.name' 2>/dev/null || true); do
        oc logs "deployment/${deploy}" -n "${OPERATOR_NAMESPACE}" --all-containers --tail=500 \
            > "${ARTIFACT_DIR}/${deploy}-logs.txt" 2>&1 || true
        log "  Saved deployment/${deploy} logs"
    done
    for ds in $(oc get daemonset -n "${OPERATOR_NAMESPACE}" --no-headers \
            -o custom-columns=':metadata.name' 2>/dev/null || true); do
        oc logs "daemonset/${ds}" -n "${OPERATOR_NAMESPACE}" --all-containers --tail=500 \
            > "${ARTIFACT_DIR}/${ds}-ds-logs.txt" 2>&1 || true
        log "  Saved daemonset/${ds} logs"
    done
    oc get events -n "${OPERATOR_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${ARTIFACT_DIR}/operator-namespace-events.txt" 2>&1 || true
fi

if [[ -z "${MODE}" ]]; then
    log "No install mode recorded, nothing to clean up"
    exit 0
fi

log "Cleanup mode: ${MODE}"

case "${MODE}" in
clusterpackage-patch)
    ORIG_PKO_IMAGE=$(cat "${SHARED_DIR}/operator-e2e-orig-pko-image" 2>/dev/null || true)
    ORIG_OP_IMAGE=$(cat "${SHARED_DIR}/operator-e2e-orig-op-image" 2>/dev/null || true)
    if [[ -n "${PACKAGE_NAME}" && -n "${ORIG_PKO_IMAGE}" ]]; then
        log "Restoring ClusterPackage '${PACKAGE_NAME}' to production images"
        PATCH="{\"spec\":{\"image\":\"${ORIG_PKO_IMAGE}\"}}"
        if [[ -n "${ORIG_OP_IMAGE}" ]]; then
            PATCH="{\"spec\":{\"image\":\"${ORIG_PKO_IMAGE}\",\"config\":{\"image\":\"${ORIG_OP_IMAGE}\"}}}"
        fi
        oc patch clusterpackage "${PACKAGE_NAME}" --type merge -p "${PATCH}" 2>/dev/null || true
        log "ClusterPackage '${PACKAGE_NAME}' restored"
    fi
    ;;

package-patch)
    ORIG_PKO_IMAGE=$(cat "${SHARED_DIR}/operator-e2e-orig-pko-image" 2>/dev/null || true)
    ORIG_OP_IMAGE=$(cat "${SHARED_DIR}/operator-e2e-orig-op-image" 2>/dev/null || true)
    if [[ -n "${PACKAGE_NAME}" && -n "${ORIG_PKO_IMAGE}" ]]; then
        log "Restoring Package '${PACKAGE_NAME}' to production images"
        PATCH="{\"spec\":{\"image\":\"${ORIG_PKO_IMAGE}\"}}"
        if [[ -n "${ORIG_OP_IMAGE}" ]]; then
            PATCH="{\"spec\":{\"image\":\"${ORIG_PKO_IMAGE}\",\"config\":{\"image\":\"${ORIG_OP_IMAGE}\"}}}"
        fi
        oc patch package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" \
            --type merge -p "${PATCH}" 2>/dev/null || true
        log "Package '${PACKAGE_NAME}' restored"
    fi
    ;;

deployment-direct)
    CONTAINER_NAME=$(cat "${SHARED_DIR}/operator-e2e-container-name" 2>/dev/null || true)
    ORIG_IMAGE=$(cat "${SHARED_DIR}/operator-e2e-orig-op-image" 2>/dev/null || true)
    if [[ -n "${PACKAGE_NAME}" && -n "${ORIG_IMAGE}" && -n "${CONTAINER_NAME}" ]]; then
        log "Restoring Deployment '${PACKAGE_NAME}' container image"
        oc set image "deployment/${PACKAGE_NAME}" \
            "${CONTAINER_NAME}=${ORIG_IMAGE}" \
            -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true
        log "Deployment '${PACKAGE_NAME}' image restored"
    fi
    ;;

daemonset-direct)
    CONTAINER_NAME=$(cat "${SHARED_DIR}/operator-e2e-container-name" 2>/dev/null || true)
    ORIG_IMAGE=$(cat "${SHARED_DIR}/operator-e2e-orig-op-image" 2>/dev/null || true)
    if [[ -n "${PACKAGE_NAME}" && -n "${ORIG_IMAGE}" && -n "${CONTAINER_NAME}" ]]; then
        log "Restoring DaemonSet '${PACKAGE_NAME}' container image"
        oc set image "daemonset/${PACKAGE_NAME}" \
            "${CONTAINER_NAME}=${ORIG_IMAGE}" \
            -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true
        log "DaemonSet '${PACKAGE_NAME}' image restored"
    fi
    ;;

package-create)
    if [[ -z "${PACKAGE_NAME}" ]]; then
        log "No Package name recorded, nothing to delete"
        exit 0
    fi
    log "Deleting test Package '${PACKAGE_NAME}' in ${OPERATOR_NAMESPACE}"
    if oc get package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        oc delete package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=120s || true
        for _i in $(seq 1 24); do
            RESULT=$(oc get package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" \
                --ignore-not-found -o name 2>&1) || true
            if [[ -z "${RESULT}" ]]; then break; fi
            sleep 5
        done
        RESULT=$(oc get package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" \
            --ignore-not-found -o name 2>&1) || true
        if [[ -n "${RESULT}" ]]; then
            log "WARNING: Package still exists, removing finalizers"
            oc patch package "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" \
                --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        fi
    fi

    # Restore the SSS-managed ConfigMap and Service we deleted during install.
    # Wait up to 60s for PKO to finish GC-ing its owned resources first.
    if [[ -s "${SHARED_DIR}/webhook-cert-cm.json" || -s "${SHARED_DIR}/validation-webhook-svc.json" ]]; then
        log "Waiting for PKO to finish removing its owned resources"
        for _i in $(seq 1 12); do
            CM=$(oc get configmap webhook-cert -n "${OPERATOR_NAMESPACE}" \
                --ignore-not-found -o name 2>/dev/null || true)
            SVC=$(oc get service validation-webhook -n "${OPERATOR_NAMESPACE}" \
                --ignore-not-found -o name 2>/dev/null || true)
            if [[ -z "${CM}" && -z "${SVC}" ]]; then break; fi
            sleep 5
        done
        log "Restoring SSS-managed resources"
        if [[ -s "${SHARED_DIR}/webhook-cert-cm.json" ]]; then
            oc apply -f "${SHARED_DIR}/webhook-cert-cm.json" 2>/dev/null || true
            log "  ConfigMap webhook-cert restored"
        fi
        if [[ -s "${SHARED_DIR}/validation-webhook-svc.json" ]]; then
            oc apply -f "${SHARED_DIR}/validation-webhook-svc.json" 2>/dev/null || true
            log "  Service validation-webhook restored"
        fi
    fi
    log "Cleanup complete"
    ;;

*)
    log "Unknown mode '${MODE}', skipping cleanup"
    ;;
esac
