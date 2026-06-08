#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

POOL_NAMESPACE="${POOL_NAMESPACE:-rosa-pool}"
POOL_TYPE="${POOL_TYPE:-classic-sts}"
POOL_REGION="${POOL_REGION:-}"
POOL_VERSION="${POOL_VERSION:-}"
POOL_CHECKOUT_TIMEOUT="${POOL_CHECKOUT_TIMEOUT_MINUTES:-30}"
POOL_HOST_KUBECONFIG="/etc/rosa-pool-manager/kubeconfig"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"

if [[ ! -f "${POOL_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Pool host kubeconfig not found at ${POOL_HOST_KUBECONFIG}"
    exit 1
fi

pool_oc() {
    oc --kubeconfig="${POOL_HOST_KUBECONFIG}" "$@"
}

# Build label selector
SELECTOR="rosa-pool/managed=true,rosa-pool/status=available,rosa-pool/type=${POOL_TYPE}"
if [[ -n "${POOL_REGION}" ]]; then
    SELECTOR="${SELECTOR},rosa-pool/region=${POOL_REGION}"
fi
if [[ -n "${POOL_VERSION}" ]]; then
    SELECTOR="${SELECTOR},rosa-pool/version=${POOL_VERSION}"
fi

log "Pool checkout starting"
log "  Type: ${POOL_TYPE}"
log "  Region: ${POOL_REGION:-any}"
log "  Version: ${POOL_VERSION:-any}"
log "  Timeout: ${POOL_CHECKOUT_TIMEOUT} minutes"
log "  Selector: ${SELECTOR}"

JOB_NAME="${JOB_NAME:-unknown-job}"
BUILD_ID="${BUILD_ID:-unknown-build}"
DEADLINE=$(($(date +%s) + POOL_CHECKOUT_TIMEOUT * 60))
ATTEMPT=0

while true; do
    NOW=$(date +%s)
    if [[ ${NOW} -ge ${DEADLINE} ]]; then
        log "ERROR: Pool checkout timed out after ${POOL_CHECKOUT_TIMEOUT} minutes"
        log "No available clusters matching selector: ${SELECTOR}"
        exit 1
    fi

    REMAINING=$(( (DEADLINE - NOW) / 60 ))
    ATTEMPT=$((ATTEMPT + 1))
    log "Attempt ${ATTEMPT} (${REMAINING}m remaining)"

    # List available clusters
    CLUSTERS_JSON=$(pool_oc get configmap -n "${POOL_NAMESPACE}" -l "${SELECTOR}" -o json 2>/dev/null || echo '{"items":[]}')
    COUNT=$(echo "${CLUSTERS_JSON}" | jq '.items | length')

    if [[ "${COUNT}" -eq 0 ]]; then
        log "No available clusters in pool. Waiting 30s..."
        sleep 30
        continue
    fi

    log "Found ${COUNT} available cluster(s), attempting claim..."

    # Try to claim each available cluster
    CLAIMED=false
    for i in $(seq 0 $((COUNT - 1))); do
        CM=$(echo "${CLUSTERS_JSON}" | jq ".items[${i}]")
        CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
        CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
        CLUSTER_NAME=$(echo "${CM}" | jq -r '.data["cluster-name"]')

        log "Trying to claim ${CM_NAME} (cluster: ${CLUSTER_ID})..."

        # Mutate the ConfigMap in memory: set status to in-use with holder info
        ACQUIRED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        MODIFIED=$(echo "${CM}" | jq '
            .metadata.labels["rosa-pool/status"] = "in-use" |
            .metadata.annotations["rosa-pool/holder"] = "'"${JOB_NAME}"'" |
            .metadata.annotations["rosa-pool/build-id"] = "'"${BUILD_ID}"'" |
            .metadata.annotations["rosa-pool/acquired-at"] = "'"${ACQUIRED_AT}"'"
        ')

        # CAS: oc replace will fail with 409 if resourceVersion changed
        if echo "${MODIFIED}" | pool_oc replace -n "${POOL_NAMESPACE}" -f - 2>/dev/null; then
            log "Claimed cluster ${CLUSTER_ID} (${CM_NAME})"
            CLAIMED=true

            # Write claim metadata to SHARED_DIR for checkin and downstream steps
            echo "${CM_NAME}" > "${SHARED_DIR}/pool-claim"
            echo "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
            echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

            # Write cluster metadata for downstream steps
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

# Log in to OCM for backplane access
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM ${OCM_LOGIN_ENV} with SSO credentials"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "Logging into OCM ${OCM_LOGIN_ENV} with offline token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

# Get cluster access via backplane
log "Getting kubeconfig for ${CLUSTER_ID} via backplane"
ocm backplane login "${CLUSTER_ID}" --multi

# Copy the backplane-generated kubeconfig to SHARED_DIR
BACKPLANE_KUBECONFIG="${HOME}/.kube/backplane/${CLUSTER_ID}/config"
if [[ -f "${BACKPLANE_KUBECONFIG}" ]]; then
    cp "${BACKPLANE_KUBECONFIG}" "${SHARED_DIR}/kubeconfig"
elif [[ -f "${HOME}/.kube/config" ]]; then
    cp "${HOME}/.kube/config" "${SHARED_DIR}/kubeconfig"
else
    log "ERROR: No kubeconfig produced by backplane login"
    exit 1
fi

# Verify cluster access
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if oc whoami &>/dev/null; then
    log "Verified cluster access: $(oc whoami --show-server)"
    log "Nodes: $(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
else
    log "WARNING: Could not verify cluster access (oc whoami failed)"
fi

log "Pool checkout complete"
log "  Cluster ID: ${CLUSTER_ID}"
log "  Pool claim: $(cat "${SHARED_DIR}/pool-claim")"
log "  Kubeconfig: ${SHARED_DIR}/kubeconfig"
