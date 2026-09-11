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

# Fallback for MC mode where install step doesn't run
if [[ -z "${OPERATOR_NAMESPACE}" && -n "${OPERATOR_NAME:-}" ]]; then
    OPERATOR_NAMESPACE="openshift-${OPERATOR_NAME}"
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

# Restore reconcile-interval if it was overridden for MC e2e testing
RMO_NS="openshift-route-monitor-operator"
RMO_CM="route-monitor-operator-config"
if oc get configmap "${RMO_CM}" -n "${RMO_NS}" -o jsonpath='{.data.reconcile-interval}' 2>/dev/null | grep -q .; then
    log "Restoring default reconcile-interval on ${RMO_CM}"
    oc patch configmap "${RMO_CM}" -n "${RMO_NS}" --type json \
        -p '[{"op":"remove","path":"/data/reconcile-interval"}]' 2>/dev/null || true
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

# Wait for the production operator to reconcile after cleanup.
# When the e2e ClusterPackage is deleted, PKO garbage-collects managed
# resources (deployments, ServiceAccounts, etc.). The production
# ClusterPackage then needs to re-deploy everything. We wait here so
# the cluster is not returned to the pool in a degraded state.
# All waits share a single 300s budget so the total time is bounded.
if [[ "${CP_DELETED}" == "true" && -n "${OPERATOR_NAME:-}" && -n "${OPERATOR_NAMESPACE}" ]]; then
    DEPLOY_NAME="${OPERATOR_NAME}"
    WAIT_BUDGET=300
    WAIT_START=$(date +%s)

    wait_remaining() {
        local elapsed=$(( $(date +%s) - WAIT_START ))
        local remaining=$(( WAIT_BUDGET - elapsed ))
        echo $(( remaining > 0 ? remaining : 0 ))
    }

    # Phase 1: poll for the operator deployment to appear
    log "Waiting for production operator deployment ${DEPLOY_NAME} to appear in ${OPERATOR_NAMESPACE} (budget: ${WAIT_BUDGET}s)"
    DEPLOY_FOUND=false
    while [[ "$(wait_remaining)" -gt 0 ]]; do
        if oc get deployment "${DEPLOY_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
            DEPLOY_FOUND=true
            break
        fi
        sleep 10
    done

    # Phase 2: wait for Available condition
    if [[ "${DEPLOY_FOUND}" == "true" ]]; then
        REMAINING=$(wait_remaining)
        if [[ "${REMAINING}" -gt 0 ]]; then
            log "Deployment ${DEPLOY_NAME} found, waiting for Available condition (${REMAINING}s remaining)"
            oc wait deployment "${DEPLOY_NAME}" -n "${OPERATOR_NAMESPACE}" \
                --for=condition=Available --timeout="${REMAINING}s" 2>/dev/null || \
                log "WARNING: Timed out waiting for ${DEPLOY_NAME} to become Available — cluster may self-heal"
        else
            log "WARNING: Budget exhausted before waiting for ${DEPLOY_NAME} Available condition — cluster may self-heal"
        fi
    else
        log "WARNING: Deployment ${DEPLOY_NAME} did not appear within budget — cluster may self-heal"
    fi

    # Phase 3: wait for additional deployments if specified (e.g. operands managed by the operator)
    if [[ -n "${OPERATOR_WAIT_DEPLOYMENTS:-}" ]]; then
        IFS=',' read -ra WAIT_DEPLOYS <<< "${OPERATOR_WAIT_DEPLOYMENTS}"
        for deploy in "${WAIT_DEPLOYS[@]}"; do
            deploy=$(echo "${deploy}" | xargs)
            [[ -z "${deploy}" ]] && continue

            REMAINING=$(wait_remaining)
            if [[ "${REMAINING}" -le 0 ]]; then
                log "WARNING: Budget exhausted, skipping wait for ${deploy} — cluster may self-heal"
                continue
            fi

            # Poll for the deployment to exist before waiting for its condition
            log "Waiting for deployment ${deploy} to appear in ${OPERATOR_NAMESPACE} (${REMAINING}s remaining)"
            EXTRA_FOUND=false
            while [[ "$(wait_remaining)" -gt 0 ]]; do
                if oc get deployment "${deploy}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
                    EXTRA_FOUND=true
                    break
                fi
                sleep 5
            done

            if [[ "${EXTRA_FOUND}" == "true" ]]; then
                REMAINING=$(wait_remaining)
                if [[ "${REMAINING}" -gt 0 ]]; then
                    log "Deployment ${deploy} found, waiting for Available condition (${REMAINING}s remaining)"
                    oc wait deployment "${deploy}" -n "${OPERATOR_NAMESPACE}" \
                        --for=condition=Available --timeout="${REMAINING}s" 2>/dev/null || \
                        log "WARNING: Timed out waiting for ${deploy} to become Available — cluster may self-heal"
                fi
            else
                log "WARNING: Deployment ${deploy} did not appear within budget — cluster may self-heal"
            fi
        done
    fi
fi

log "Cleanup complete"
