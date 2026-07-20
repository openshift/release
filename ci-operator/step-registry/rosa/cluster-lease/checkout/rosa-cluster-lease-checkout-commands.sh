#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

LEASE_NAMESPACE="${LEASE_NAMESPACE:-rosa-cluster-lease}"
LEASE_TYPE="${LEASE_TYPE:-classic-sts}"
LEASE_ENV="${LEASE_ENV:-}"
LEASE_REGION="${LEASE_REGION:-}"
LEASE_VERSION="${LEASE_VERSION:-}"
LEASE_CHECKOUT_TIMEOUT="${LEASE_CHECKOUT_TIMEOUT_MINUTES:-30}"
LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Lease host kubeconfig not found at ${LEASE_HOST_KUBECONFIG}"
    exit 1
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

# Build label selector
SELECTOR="rosa-cluster-lease/managed=true,rosa-cluster-lease/status=available,rosa-cluster-lease/type=${LEASE_TYPE}"
if [[ -n "${LEASE_ENV}" ]]; then
    SELECTOR="${SELECTOR},rosa-cluster-lease/env=${LEASE_ENV}"
fi
if [[ -n "${LEASE_REGION}" ]]; then
    SELECTOR="${SELECTOR},rosa-cluster-lease/region=${LEASE_REGION}"
fi
if [[ -n "${LEASE_VERSION}" ]]; then
    SELECTOR="${SELECTOR},rosa-cluster-lease/version=${LEASE_VERSION}"
fi

log "Lease checkout starting"
log "  Type: ${LEASE_TYPE}"
log "  Env: ${LEASE_ENV:-any}"
log "  Region: ${LEASE_REGION:-any}"
log "  Version: ${LEASE_VERSION:-any}"
log "  Timeout: ${LEASE_CHECKOUT_TIMEOUT} minutes"
log "  Selector: ${SELECTOR}"

JOB_NAME="${JOB_NAME:-unknown-job}"
BUILD_ID="${BUILD_ID:-unknown-build}"
DEADLINE=$(($(date +%s) + LEASE_CHECKOUT_TIMEOUT * 60))
ATTEMPT=0

while true; do
    NOW=$(date +%s)
    if [[ ${NOW} -ge ${DEADLINE} ]]; then
        log "ERROR: Lease checkout timed out after ${LEASE_CHECKOUT_TIMEOUT} minutes"
        log "No available clusters matching selector: ${SELECTOR}"
        exit 1
    fi

    REMAINING=$(( (DEADLINE - NOW) / 60 ))
    ATTEMPT=$((ATTEMPT + 1))
    log "Attempt ${ATTEMPT} (${REMAINING}m remaining)"

    CLUSTERS_JSON=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "${SELECTOR}" -o json 2>/dev/null || echo '{"items":[]}')
    COUNT=$(echo "${CLUSTERS_JSON}" | jq '.items | length')

    if [[ "${COUNT}" -eq 0 ]]; then
        log "No available clusters in lease inventory. Waiting 30s..."
        sleep 30
        continue
    fi

    log "Found ${COUNT} available cluster(s), attempting claim..."

    CLAIMED=false
    for i in $(seq 0 $((COUNT - 1))); do
        CM=$(echo "${CLUSTERS_JSON}" | jq ".items[${i}]")
        CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
        CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
        CLUSTER_NAME=$(echo "${CM}" | jq -r '.data["cluster-name"]')

        log "Trying to claim ${CM_NAME} (cluster: ${CLUSTER_ID})..."

        ACQUIRED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        MODIFIED=$(echo "${CM}" | jq '
            .metadata.labels["rosa-cluster-lease/status"] = "in-use" |
            .metadata.annotations["rosa-cluster-lease/holder"] = "'"${JOB_NAME}"'" |
            .metadata.annotations["rosa-cluster-lease/build-id"] = "'"${BUILD_ID}"'" |
            .metadata.annotations["rosa-cluster-lease/acquired-at"] = "'"${ACQUIRED_AT}"'"
        ')

        if echo "${MODIFIED}" | lease_oc replace -n "${LEASE_NAMESPACE}" -f - 2>/dev/null; then
            log "Claimed cluster ${CLUSTER_ID} (${CM_NAME})"
            CLAIMED=true

            echo "${CM_NAME}" > "${SHARED_DIR}/lease-claim"
            echo "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
            echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

            echo "${CM}" | jq -r '.data.region // empty' > "${SHARED_DIR}/cluster-region"
            echo "${CM}" | jq -r '.data["ocm-env"] // empty' > "${SHARED_DIR}/ocm-env"
            echo "${CM}" | jq -r '.data["api-url"] // empty' > "${SHARED_DIR}/api-url"

            break
        else
            log "Conflict on ${CM_NAME} (another job claimed it). Trying next..."
        fi
    done

    if [[ "${CLAIMED}" == "true" ]]; then
        break
    fi

    log "All available clusters were claimed by other jobs. Waiting 15s..."
    sleep 15
done

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Cluster claimed: ${CLUSTER_ID}"

CLAIMED_OCM_ENV=$(cat "${SHARED_DIR}/ocm-env" 2>/dev/null || true)
LOGIN_ENV="${CLAIMED_OCM_ENV:-${OCM_LOGIN_ENV}}"

SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM ${LOGIN_ENV} with SSO credentials"
    ocm login --url "${LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "Logging into OCM ${LOGIN_ENV} with offline token"
    ocm login --url "${LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

log "Fetching kubeconfig for ${CLUSTER_ID} from OCM"
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" | jq -r '.kubeconfig' > "${SHARED_DIR}/kubeconfig"

if [[ ! -s "${SHARED_DIR}/kubeconfig" ]]; then
    log "ERROR: Failed to fetch kubeconfig from OCM for ${CLUSTER_ID}"
    exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if oc whoami &>/dev/null; then
    CURRENT_SERVER="$(oc whoami --show-server)"
    EXPECTED_SERVER="$(cat "${SHARED_DIR}/api-url" 2>/dev/null || true)"
    if [[ -n "${EXPECTED_SERVER}" && "${CURRENT_SERVER}" != *"${CLUSTER_ID}"* && "${CURRENT_SERVER}" != "${EXPECTED_SERVER}" ]]; then
        log "ERROR: Kubeconfig server mismatch. Expected ${EXPECTED_SERVER}, got ${CURRENT_SERVER}"
        exit 1
    fi
    log "Verified cluster access: ${CURRENT_SERVER}"
    log "Nodes: $(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
else
    log "WARNING: Could not verify cluster access (oc whoami failed)"
fi

log "Lease checkout complete"
log "  Cluster ID: ${CLUSTER_ID}"
log "  Lease claim: $(cat "${SHARED_DIR}/lease-claim")"
log "  Kubeconfig: ${SHARED_DIR}/kubeconfig"
