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

PREEXISTING_CRDS_FILE="${SHARED_DIR}/operator-preexisting-crds"
PROD_CP_BACKUP="${SHARED_DIR}/production-clusterpackage.yaml"
crd_was_preexisting() {
    grep -Fqx -- "$1" "${PREEXISTING_CRDS_FILE}" 2>/dev/null
}

# Stop the active ObjectSet from restoring CRD metadata while it is detached.
if oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" &>/dev/null; then
    log "Pausing ClusterPackage ${CLUSTER_PACKAGE_NAME} before orphaning CRDs"
    oc patch clusterpackage "${CLUSTER_PACKAGE_NAME}" --type merge \
        -p '{"spec":{"paused":true}}' >/dev/null
    oc wait clusterpackage "${CLUSTER_PACKAGE_NAME}" \
        --for='jsonpath={.status.conditions[?(@.type=="Paused")].status}=True' --timeout=120s
fi

# ──────────────────────────────────────────────────────────────────────
# CRITICAL: Orphan CRDs BEFORE deleting the e2e ClusterPackage.
# ──────────────────────────────────────────────────────────────────────
# Same cascade prevention as in the install step:
# CP → owns → COS → own → CRDs (via ownerRefs) → CRD deletion removes CRs.
# Clear ownerReferences first so CRDs (and their CRs) survive CP deletion.
if [[ -n "${OPERATOR_CRDS:-}" ]]; then
    orphan_failed=false
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        if ! crd_was_preexisting "${crd}"; then
            log "CRD ${crd} was created by the test; leaving it owned for garbage collection"
            continue
        fi
        if CRD_LOOKUP=$(oc get crd "${crd}" --ignore-not-found -o name 2>/dev/null); then
            if [[ -z "${CRD_LOOKUP}" ]]; then
                log "CRD ${crd} is absent; no ownership to clear"
                continue
            fi
            log "Orphaning CRD ${crd} from e2e ClusterObjectSets before CP deletion"
            oc patch crd "${crd}" --type merge \
                -p '{"metadata":{"ownerReferences":[],"annotations":{"package-operator.run/revision":null}}}' \
                2>/dev/null || { log "ERROR: Failed to orphan CRD ${crd}"; orphan_failed=true; }
        else
            log "ERROR: Failed to look up CRD ${crd}"
            orphan_failed=true
        fi
    done
    if [[ "${orphan_failed}" == "true" ]]; then
        log "ERROR: Refusing to delete ClusterPackage — CRD orphan patches failed, cascade protection is incomplete"
        exit 1
    fi
fi

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
    # oc get failed — distinguish "not found" from API/auth errors.
    # Only treat confirmed absence as deletion; API errors leave
    # CP_DELETED=false so we do not restore into an ambiguous state.
    GET_ERR=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" 2>&1) || true
    if echo "${GET_ERR}" | grep -qi "not found"; then
        CP_DELETED="true"
    else
        log "WARNING: Could not confirm e2e ClusterPackage status (API error?) — skipping post-deletion cleanup"
    fi
fi

if [[ "${CP_DELETED}" != "true" ]]; then
    log "ERROR: ClusterPackage ${CLUSTER_PACKAGE_NAME} was not deleted"
    exit 1
fi

# Do not race the restored production package against a terminating e2e
# ClusterObjectSet that can still reconcile or delete shared resources.
for _i in $(seq 1 24); do
    ALL_OBJECTSETS=$(oc get clusterobjectset --no-headers \
        -o custom-columns=':metadata.name')
    E2E_OBJECTSETS=$(echo "${ALL_OBJECTSETS}" | grep "^${CLUSTER_PACKAGE_NAME}-" || true)
    [[ -z "${E2E_OBJECTSETS}" ]] && break
    sleep 5
done
if [[ -n "${E2E_OBJECTSETS}" ]]; then
    log "ERROR: e2e ClusterObjectSets still exist: ${E2E_OBJECTSETS}"
    exit 1
fi

# Re-label only CRDs that predated the test. Clear the revision annotation so
# a newly restored revision-1 production package can adopt them.
if [[ "${CP_DELETED}" == "true" && -n "${OPERATOR_CRDS:-}" && -n "${OPERATOR_NAME:-}" ]]; then
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        if ! crd_was_preexisting "${crd}"; then
            oc delete crd "${crd}" --ignore-not-found --timeout=60s
            continue
        fi
        if oc get crd "${crd}" &>/dev/null; then
            if [[ -f "${PROD_CP_BACKUP}" ]]; then
                log "Re-labeling CRD ${crd} for production ClusterPackage ${OPERATOR_NAME}"
                oc patch crd "${crd}" --type merge \
                    -p '{"metadata":{"annotations":{"package-operator.run/revision":null},"labels":{"package-operator.run/instance":"'"${OPERATOR_NAME}"'"}}}' >/dev/null
            else
                oc label crd "${crd}" package-operator.run/instance- >/dev/null 2>&1 || true
            fi
        fi
    done
fi

# Restore the production ClusterPackage that install backed up.
# Without this, the cluster returns to the pool missing its production
# operator until Hive resyncs (~2h), contaminating the lease pool.
PRODUCTION_CP_RESTORED=false
if [[ "${CP_DELETED}" == "true" && -n "${OPERATOR_NAME:-}" ]]; then
    if [[ -f "${PROD_CP_BACKUP}" ]]; then
        log "Restoring production ClusterPackage ${OPERATOR_NAME} from backup"
        oc apply -f "${PROD_CP_BACKUP}"
        PRODUCTION_CP_RESTORED=true
        log "Production ClusterPackage ${OPERATOR_NAME} restored"
    else
        log "No production ClusterPackage existed before the test; skipping production restore"
    fi
fi

# Wait for the production operator to reconcile after cleanup.
# When the e2e ClusterPackage is deleted, PKO garbage-collects managed
# resources (deployments, ServiceAccounts, etc.). The production
# ClusterPackage then needs to re-deploy everything. We wait here so
# the cluster is not returned to the pool in a degraded state.
# All waits share a single 300s budget so the total time is bounded.
if [[ "${PRODUCTION_CP_RESTORED}" == "true" && -n "${OPERATOR_NAMESPACE}" ]]; then
    # Skip the deployment wait if no production ClusterPackage was backed up
    # during install — there is nothing to wait for.
    if [[ ! -s "${SHARED_DIR}/had-production-cp" ]]; then
        log "No production ClusterPackage was present before the test — skipping deployment wait"
    else
    DEPLOY_NAME="${OPERATOR_DEPLOYMENT_NAME:-${OPERATOR_NAME}}"
    WAIT_BUDGET=600
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

    # Phase 4: if PORT_FORWARD_SVC is set, poll for the service to exist
    # so the cluster is not returned with a missing service endpoint.
    if [[ -n "${PORT_FORWARD_SVC:-}" ]]; then
        PF_NS="${PORT_FORWARD_SVC%%/*}"
        PF_SVC_PORT="${PORT_FORWARD_SVC#*/}"
        PF_SVC="${PF_SVC_PORT%%:*}"

        REMAINING=$(wait_remaining)
        if [[ "${REMAINING}" -gt 0 ]]; then
            log "Waiting for service ${PF_SVC} to appear in ${PF_NS} (${REMAINING}s remaining)"
            SVC_FOUND=false
            while [[ "$(wait_remaining)" -gt 0 ]]; do
                if oc get svc "${PF_SVC}" -n "${PF_NS}" &>/dev/null; then
                    SVC_FOUND=true
                    break
                fi
                sleep 5
            done

            if [[ "${SVC_FOUND}" == "true" ]]; then
                log "Service ${PF_SVC} is present in ${PF_NS}"
            else
                log "WARNING: Service ${PF_SVC} did not appear in ${PF_NS} within budget — cluster may self-heal"
            fi
        else
            log "WARNING: Budget exhausted, skipping wait for service ${PF_SVC} — cluster may self-heal"
        fi
    fi
    fi # end of had-production-cp else branch
fi

log "Cleanup complete"
