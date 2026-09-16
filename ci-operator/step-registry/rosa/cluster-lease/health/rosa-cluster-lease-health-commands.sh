#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

LEASE_NAMESPACE="${LEASE_NAMESPACE:-rosa-cluster-lease}"
LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"
STALE_LEASE_HOURS="${STALE_LEASE_HOURS:-4}"

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Lease host kubeconfig not found at ${LEASE_HOST_KUBECONFIG}"
    exit 1
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

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

CURRENT_OCM_ENV="${OCM_LOGIN_ENV}"

ocm_ensure_env() {
    local target_env="$1"
    if [[ "${CURRENT_OCM_ENV}" == "${target_env}" ]]; then
        return 0
    fi
    if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
        ocm login --url "${target_env}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
    elif [[ -n "${OCM_TOKEN}" ]]; then
        ocm login --url "${target_env}" --token "${OCM_TOKEN}"
    fi
    CURRENT_OCM_ENV="${target_env}"
}

ALL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json)
TOTAL=$(echo "${ALL_CMS}" | jq '.items | length')

log "Lease health check: ${TOTAL} cluster(s) in inventory"

HEALTHY=0
UNHEALTHY=0
RECOVERED=0
NOW_EPOCH=$(date +%s)
STALE_THRESHOLD=$((STALE_LEASE_HOURS * 3600))

REPORT="${ARTIFACT_DIR}/lease-health-report.txt"
echo "Lease Health Report - $(date -u)" > "${REPORT}"
echo "================================" >> "${REPORT}"

for i in $(seq 0 $((TOTAL - 1))); do
    CM=$(echo "${ALL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    STATUS=$(echo "${CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    HOLDER=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
    ACQUIRED_AT=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/acquired-at"] // ""')

    echo "" >> "${REPORT}"
    echo "Cluster: ${CM_NAME} (${CLUSTER_ID})" >> "${REPORT}"
    echo "  Status: ${STATUS}" >> "${REPORT}"

    if [[ "${STATUS}" == "in-use" && -n "${ACQUIRED_AT}" ]]; then
        ACQUIRED_EPOCH=$(date -d "${ACQUIRED_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ACQUIRED_AT}" +%s 2>/dev/null || echo "0")
        LEASE_AGE=$(( NOW_EPOCH - ACQUIRED_EPOCH ))

        if [[ ${LEASE_AGE} -gt ${STALE_THRESHOLD} ]]; then
            LEASE_HOURS=$(( LEASE_AGE / 3600 ))
            log "STALE LEASE: ${CM_NAME} held by ${HOLDER} for ${LEASE_HOURS}h (threshold: ${STALE_LEASE_HOURS}h)"
            echo "  STALE LEASE: held by ${HOLDER} for ${LEASE_HOURS}h" >> "${REPORT}"

            RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "available" },
                    "annotations": {
                        "rosa-cluster-lease/holder": "",
                        "rosa-cluster-lease/build-id": "",
                        "rosa-cluster-lease/released-at": "'"${RELEASED_AT}"'",
                        "rosa-cluster-lease/recovered-by": "health-check"
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

    if [[ "${STATUS}" == "in-use" ]]; then
        HEALTHY=$((HEALTHY + 1))
        continue
    fi

    # Skip health checks for provisioning clusters
    if [[ "${STATUS}" == "provisioning" ]]; then
        HEALTHY=$((HEALTHY + 1))
        echo "  Provisioning (skipped)" >> "${REPORT}"
        continue
    fi

    CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    OCM_STATUS=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}" 2>/dev/null | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unreachable")
    echo "  OCM status: ${OCM_STATUS}" >> "${REPORT}"

    if [[ "${OCM_STATUS}" != "ready" ]]; then
        log "UNHEALTHY: ${CM_NAME} OCM status is ${OCM_STATUS}"

        if [[ "${STATUS}" != "error" ]]; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "error" },
                    "annotations": { "rosa-cluster-lease/error-reason": "OCM status: '"${OCM_STATUS}"'", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                }
            }' || true
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        continue
    fi

    # --- ClusterPackage health check ---
    # Fetch a cluster-admin kubeconfig from OCM to inspect in-cluster state.
    # If the kubeconfig fetch fails (transient OCM issue, cluster not yet
    # accessible), skip the CP check — do NOT mark the cluster as error.
    CLUSTER_KUBECONFIG=$(mktemp)
    CP_CHECK_SKIPPED=""
    if ! ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null | jq -r '.kubeconfig' > "${CLUSTER_KUBECONFIG}" 2>/dev/null || [[ ! -s "${CLUSTER_KUBECONFIG}" ]]; then
        log "WARNING: ${CM_NAME} could not fetch cluster kubeconfig from OCM, skipping ClusterPackage check"
        CP_CHECK_SKIPPED="true"
    fi

    if [[ -z "${CP_CHECK_SKIPPED}" ]]; then
        # Determine the expected ClusterPackage set from the lease config
        CLUSTER_TYPE=$(echo "${CM}" | jq -r '.data["cluster-type"] // "classic-sts"')
        EXPECTED_CPS=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o jsonpath="{.data['expected-clusterpackages-${CLUSTER_TYPE}']}" 2>/dev/null || true)
        if [[ -z "${EXPECTED_CPS}" ]]; then
            EXPECTED_CPS=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o jsonpath='{.data.expected-clusterpackages}' 2>/dev/null || true)
        fi
        if [[ -z "${EXPECTED_CPS}" ]]; then
            # Default: the 9 managed operator ClusterPackages
            EXPECTED_CPS="addon-operator configure-alertmanager-operator managed-node-metadata-operator managed-upgrade-operator ocm-agent-operator osd-metrics-exporter rbac-permissions-operator route-monitor-operator splunk-forwarder-operator"
        fi

        # Get actual ClusterPackages with the managed label from the cluster
        ACTUAL_CP_JSON=""
        ACTUAL_CP_JSON=$(oc --kubeconfig="${CLUSTER_KUBECONFIG}" get clusterpackage -l "hive.openshift.io/managed=true" --request-timeout=15s -o json 2>/dev/null) || true

        if [[ -n "${ACTUAL_CP_JSON}" ]]; then
            # Check for missing CPs (expected but not present)
            ACTUAL_CP_NAMES=$(echo "${ACTUAL_CP_JSON}" | jq -r '.items[].metadata.name' 2>/dev/null | sort) || true
            CP_ISSUES=""
            for expected_cp in ${EXPECTED_CPS}; do
                if ! echo "${ACTUAL_CP_NAMES}" | grep -qx "${expected_cp}"; then
                    CP_ISSUES="${CP_ISSUES}missing:${expected_cp} "
                fi
            done

            # Check for degraded CPs (present but Available != True)
            DEGRADED_CPS=$(echo "${ACTUAL_CP_JSON}" | jq -r '
                .items[] |
                select(any(.status.conditions[]?;
                    .type == "Available" and .status == "True") | not) |
                .metadata.name' 2>/dev/null) || true
            for degraded_cp in ${DEGRADED_CPS}; do
                CP_ISSUES="${CP_ISSUES}degraded:${degraded_cp} "
            done

            if [[ -n "${CP_ISSUES}" ]]; then
                CP_ISSUES="${CP_ISSUES% }"
                log "UNHEALTHY: ${CM_NAME} ClusterPackage issues: ${CP_ISSUES}"
                echo "  ClusterPackage issues: ${CP_ISSUES}" >> "${REPORT}"
                if [[ "${STATUS}" != "error" ]]; then
                    lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                        "metadata": {
                            "labels": { "rosa-cluster-lease/status": "error" },
                            "annotations": { "rosa-cluster-lease/error-reason": "ClusterPackage: '"${CP_ISSUES}"'", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                        }
                    }' || true
                fi
                rm -f "${CLUSTER_KUBECONFIG}"
                UNHEALTHY=$((UNHEALTHY + 1))
                continue
            fi
        else
            log "WARNING: ${CM_NAME} could not list ClusterPackages, skipping CP check"
        fi
    fi
    rm -f "${CLUSTER_KUBECONFIG}"
    # --- End ClusterPackage health check ---

    if [[ "${STATUS}" == "error" ]]; then
        log "RESTORED: ${CM_NAME} is healthy again, setting to available"
        lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
            "metadata": {
                "labels": { "rosa-cluster-lease/status": "available" },
                "annotations": { "rosa-cluster-lease/error-reason": "", "rosa-cluster-lease/error-at": "" }
            }
        }' || true
        echo "  RESTORED to available" >> "${REPORT}"
    fi

    HEALTHY=$((HEALTHY + 1))
done

echo "" >> "${REPORT}"
echo "Summary: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} recovered" >> "${REPORT}"

log "Lease health check complete: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} stale leases recovered"
cat "${REPORT}"
