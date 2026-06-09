#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

POOL_NAMESPACE="${POOL_NAMESPACE:-rosa-pool}"
POOL_HOST_KUBECONFIG="/etc/rosa-pool-manager/kubeconfig"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"
STALE_LEASE_HOURS="${STALE_LEASE_HOURS:-4}"

if [[ ! -f "${POOL_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Pool host kubeconfig not found at ${POOL_HOST_KUBECONFIG}"
    exit 1
fi

pool_oc() {
    oc --kubeconfig="${POOL_HOST_KUBECONFIG}" "$@"
}

# Log in to OCM for cluster status checks and kubeconfig access
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

# Get all pool clusters
ALL_CMS=$(pool_oc get configmap -n "${POOL_NAMESPACE}" -l "rosa-pool/managed=true" -o json)
TOTAL=$(echo "${ALL_CMS}" | jq '.items | length')

log "Pool health check: ${TOTAL} cluster(s) in pool"

HEALTHY=0
UNHEALTHY=0
RECOVERED=0
NOW_EPOCH=$(date +%s)
STALE_THRESHOLD=$((STALE_LEASE_HOURS * 3600))

REPORT="${ARTIFACT_DIR}/pool-health-report.txt"
echo "Pool Health Report - $(date -u)" > "${REPORT}"
echo "================================" >> "${REPORT}"

for i in $(seq 0 $((TOTAL - 1))); do
    CM=$(echo "${ALL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    STATUS=$(echo "${CM}" | jq -r '.metadata.labels["rosa-pool/status"]')
    HOLDER=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-pool/holder"] // ""')
    ACQUIRED_AT=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-pool/acquired-at"] // ""')

    echo "" >> "${REPORT}"
    echo "Cluster: ${CM_NAME} (${CLUSTER_ID})" >> "${REPORT}"
    echo "  Status: ${STATUS}" >> "${REPORT}"

    # Check for stale leases
    if [[ "${STATUS}" == "in-use" && -n "${ACQUIRED_AT}" ]]; then
        ACQUIRED_EPOCH=$(date -d "${ACQUIRED_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ACQUIRED_AT}" +%s 2>/dev/null || echo "0")
        LEASE_AGE=$(( NOW_EPOCH - ACQUIRED_EPOCH ))

        if [[ ${LEASE_AGE} -gt ${STALE_THRESHOLD} ]]; then
            LEASE_HOURS=$(( LEASE_AGE / 3600 ))
            log "STALE LEASE: ${CM_NAME} held by ${HOLDER} for ${LEASE_HOURS}h (threshold: ${STALE_LEASE_HOURS}h)"
            echo "  STALE LEASE: held by ${HOLDER} for ${LEASE_HOURS}h" >> "${REPORT}"

            RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if pool_oc patch configmap "${CM_NAME}" -n "${POOL_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-pool/status": "available" },
                    "annotations": {
                        "rosa-pool/holder": "",
                        "rosa-pool/build-id": "",
                        "rosa-pool/released-at": "'"${RELEASED_AT}"'",
                        "rosa-pool/recovered-by": "health-check"
                    }
                }
            }'; then
                log "Recovered stale lease on ${CM_NAME}"
                echo "  RECOVERED: lease force-released" >> "${REPORT}"
                RECOVERED=$((RECOVERED + 1))
                STATUS="available"
            fi
        else
            log "${CM_NAME}: in-use by ${HOLDER} (${LEASE_AGE}s ago, within threshold)"
            echo "  Holder: ${HOLDER} (${LEASE_AGE}s ago)" >> "${REPORT}"
            HEALTHY=$((HEALTHY + 1))
            continue
        fi
    fi

    # Skip health checks for in-use clusters (don't interfere with running tests)
    if [[ "${STATUS}" == "in-use" ]]; then
        HEALTHY=$((HEALTHY + 1))
        continue
    fi

    # Check OCM cluster status
    OCM_STATUS=$(ocm describe cluster "${CLUSTER_ID}" --json 2>/dev/null | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unreachable")

    if [[ "${OCM_STATUS}" != "ready" ]]; then
        log "UNHEALTHY: ${CM_NAME} OCM status is ${OCM_STATUS}"
        echo "  OCM status: ${OCM_STATUS} (UNHEALTHY)" >> "${REPORT}"

        if [[ "${STATUS}" != "error" ]]; then
            pool_oc patch configmap "${CM_NAME}" -n "${POOL_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-pool/status": "error" },
                    "annotations": { "rosa-pool/error-reason": "OCM status: '"${OCM_STATUS}"'" }
                }
            }' || true
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        continue
    fi

    # Check API server reachability via OCM kubeconfig
    CLUSTER_KC=$(mktemp)
    if ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null | jq -r '.kubeconfig' > "${CLUSTER_KC}" && [[ -s "${CLUSTER_KC}" ]]; then
        if ! NODES_OUTPUT=$(oc --kubeconfig="${CLUSTER_KC}" get nodes --no-headers 2>/dev/null); then
            log "UNHEALTHY: ${CM_NAME} failed to query nodes"
            echo "  Nodes: query failed (UNHEALTHY)" >> "${REPORT}"
            if [[ "${STATUS}" != "error" ]]; then
                pool_oc patch configmap "${CM_NAME}" -n "${POOL_NAMESPACE}" --type merge -p '{
                    "metadata": {
                        "labels": { "rosa-pool/status": "error" },
                        "annotations": { "rosa-pool/error-reason": "Node query failed" }
                    }
                }' || true
            fi
            UNHEALTHY=$((UNHEALTHY + 1))
            continue
        fi

        NODE_COUNT=$(printf "%s\n" "${NODES_OUTPUT}" | sed '/^$/d' | wc -l | tr -d ' ')
        READY_NODES=$(printf "%s\n" "${NODES_OUTPUT}" | grep -c " Ready" || true)

        echo "  OCM status: ready" >> "${REPORT}"
        echo "  Nodes: ${READY_NODES}/${NODE_COUNT} ready" >> "${REPORT}"

        if [[ "${READY_NODES}" -eq 0 ]]; then
            log "UNHEALTHY: ${CM_NAME} has no ready nodes"
            if [[ "${STATUS}" != "error" ]]; then
                pool_oc patch configmap "${CM_NAME}" -n "${POOL_NAMESPACE}" --type merge -p '{
                    "metadata": {
                        "labels": { "rosa-pool/status": "error" },
                        "annotations": { "rosa-pool/error-reason": "No ready nodes" }
                    }
                }' || true
            fi
            UNHEALTHY=$((UNHEALTHY + 1))
            continue
        fi
    else
        log "UNHEALTHY: ${CM_NAME} OCM kubeconfig fetch failed"
        echo "  OCM kubeconfig: FAILED" >> "${REPORT}"

        if [[ "${STATUS}" != "error" ]]; then
            pool_oc patch configmap "${CM_NAME}" -n "${POOL_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-pool/status": "error" },
                    "annotations": { "rosa-pool/error-reason": "Backplane login failed" }
                }
            }' || true
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        continue
    fi

    # If cluster was in error state but is now healthy, restore to available
    if [[ "${STATUS}" == "error" ]]; then
        log "RESTORED: ${CM_NAME} is healthy again, setting to available"
        pool_oc patch configmap "${CM_NAME}" -n "${POOL_NAMESPACE}" --type merge -p '{
            "metadata": {
                "labels": { "rosa-pool/status": "available" },
                "annotations": { "rosa-pool/error-reason": "" }
            }
        }' || true
        echo "  RESTORED to available" >> "${REPORT}"
    fi

    HEALTHY=$((HEALTHY + 1))
done

echo "" >> "${REPORT}"
echo "Summary: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} recovered" >> "${REPORT}"

log "Pool health check complete: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} stale leases recovered"
cat "${REPORT}"
