#!/bin/bash
set -euo pipefail

declare ACM_NAMESPACE="${ACM_NAMESPACE:-ocm}"
declare MCE_NAMESPACE="${MCE_NAMESPACE:-multicluster-engine}"
declare HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-600}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

check_pods_in_namespace() {
    local ns="$1"
    local pod_count
    pod_count=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    if ((pod_count == 0)); then
        log "WARNING: No pods found in namespace ${ns}"
        return 1
    fi

    local unhealthy
    unhealthy=$(oc get pods -n "$ns" --no-headers 2>/dev/null \
        | awk '$3 != "Running" && $3 != "Succeeded" && $3 != "Completed" {print $0}')

    if [[ -n "$unhealthy" ]]; then
        log "Unhealthy pods in ${ns}:"
        echo "$unhealthy"
        return 1
    fi

    log "All ${pod_count} pods in ${ns} are healthy"
    return 0
}

main() {
    log "=== ACM/MCE Pods Health Check ==="

    oc get pods -n "$ACM_NAMESPACE" -o wide > "${ARTIFACT_DIR}/acm-pods.txt" 2>/dev/null || true
    oc get pods -n "$MCE_NAMESPACE" -o wide > "${ARTIFACT_DIR}/mce-pods.txt" 2>/dev/null || true

    local deadline=$((SECONDS + HEALTH_CHECK_TIMEOUT))
    local all_healthy=false

    while ((SECONDS < deadline)); do
        local failed=false
        check_pods_in_namespace "$ACM_NAMESPACE" || failed=true
        check_pods_in_namespace "$MCE_NAMESPACE" || failed=true

        if [[ "$failed" == "false" ]]; then
            all_healthy=true
            break
        fi

        log "Retrying in 30s..."
        sleep 30
    done

    oc get pods -n "$ACM_NAMESPACE" -o wide > "${ARTIFACT_DIR}/acm-pods-final.txt" 2>/dev/null || true
    oc get pods -n "$MCE_NAMESPACE" -o wide > "${ARTIFACT_DIR}/mce-pods-final.txt" 2>/dev/null || true

    if [[ "$all_healthy" == "true" ]]; then
        log "=== All ACM/MCE pods are healthy ==="
        return 0
    fi

    log "ERROR: Some pods did not reach Running/Succeeded within ${HEALTH_CHECK_TIMEOUT}s"
    oc get pods -n "$ACM_NAMESPACE" -o yaml > "${ARTIFACT_DIR}/acm-pods-debug.yaml" 2>/dev/null || true
    oc get pods -n "$MCE_NAMESPACE" -o yaml > "${ARTIFACT_DIR}/mce-pods-debug.yaml" 2>/dev/null || true
    return 1
}
main
