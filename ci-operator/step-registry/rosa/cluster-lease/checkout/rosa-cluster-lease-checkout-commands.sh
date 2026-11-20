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
# Mount path of the lease host credential declared by this step's `credentials`
# stanza. The default is what CI runs with: this step's `env` stanza does not
# declare the variable, so it is not part of the interface a job configures
# through the registry, and a test keeps it that way. The override
# follows the same shape as GCP_CREDENTIALS_FILE and OSD_AWS_CREDENTIALS_DIR in
# the sibling controller step, and it is what lets the offline tests under
# hack/tests drive this script end to end against a fixture; the default path
# itself is asserted there so it cannot drift.
LEASE_HOST_KUBECONFIG="${LEASE_HOST_KUBECONFIG:-/etc/rosa-cluster-lease-manager/sa.rosa-cluster-lease-manager.hosted-mgmt.config}"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"
OPERATOR_NAME="${OPERATOR_NAME:-}"
LEASE_FAIL_FAST_ON_EXHAUSTED="${LEASE_FAIL_FAST_ON_EXHAUSTED:-true}"

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Lease host kubeconfig not found at ${LEASE_HOST_KUBECONFIG}"
    exit 1
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

# Build label selector
# DIAG_SELECTOR matches all managed clusters in the pool (no status filter) for diagnostic logging.
# SELECTOR further restricts to available clusters in exclusive mode.
DIAG_SELECTOR="rosa-cluster-lease/managed=true,rosa-cluster-lease/type=${LEASE_TYPE}"
if [[ -n "${LEASE_ENV}" ]]; then
    DIAG_SELECTOR="${DIAG_SELECTOR},rosa-cluster-lease/env=${LEASE_ENV}"
fi
if [[ -n "${LEASE_REGION}" ]]; then
    DIAG_SELECTOR="${DIAG_SELECTOR},rosa-cluster-lease/region=${LEASE_REGION}"
fi
if [[ -n "${LEASE_VERSION}" ]]; then
    DIAG_SELECTOR="${DIAG_SELECTOR},rosa-cluster-lease/version=${LEASE_VERSION}"
fi

# When OPERATOR_NAME is set, query all managed clusters (not just available)
# and filter by operator in-script to support concurrent use
if [[ -n "${OPERATOR_NAME}" ]]; then
    SELECTOR="${DIAG_SELECTOR}"
else
    SELECTOR="${DIAG_SELECTOR},rosa-cluster-lease/status=available"
fi

log_cluster_inventory() {
    local clusters_json="$1"
    local total i cm name status ops holder build_id acquired_at
    total=$(echo "${clusters_json}" | jq '.items | length')
    log "Cluster inventory (${total} total):"
    for i in $(seq 0 $((total - 1))); do
        cm=$(echo "${clusters_json}" | jq ".items[${i}]")
        name=$(echo "${cm}" | jq -r '.metadata.name')
        status=$(echo "${cm}" | jq -r '.metadata.labels["rosa-cluster-lease/status"] // "unknown"')
        ops=$(echo "${cm}" | jq -r '.metadata.annotations["rosa-cluster-lease/operators"] // ""')
        holder=$(echo "${cm}" | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
        build_id=$(echo "${cm}" | jq -r '.metadata.annotations["rosa-cluster-lease/build-id"] // ""')
        acquired_at=$(echo "${cm}" | jq -r '.metadata.annotations["rosa-cluster-lease/acquired-at"] // ""')
        log "  ${name}: status=${status} ops=[${ops}] holder=${holder:-none} build=${build_id:-none} acquired=${acquired_at:-never}"
    done
}

get_pool_status_summary() {
    local clusters_json="$1"
    local available in_use maintenance error_count other
    available=$(echo "${clusters_json}" | jq '[.items[] | select(.metadata.labels["rosa-cluster-lease/status"] == "available")] | length')
    in_use=$(echo "${clusters_json}" | jq '[.items[] | select(.metadata.labels["rosa-cluster-lease/status"] == "in-use")] | length')
    maintenance=$(echo "${clusters_json}" | jq '[.items[] | select(.metadata.labels["rosa-cluster-lease/status"] == "maintenance")] | length')
    error_count=$(echo "${clusters_json}" | jq '[.items[] | select(.metadata.labels["rosa-cluster-lease/status"] == "error")] | length')
    other=$(echo "${clusters_json}" | jq '[.items[] | select(.metadata.labels["rosa-cluster-lease/status"] | . != "available" and . != "in-use" and . != "maintenance" and . != "error")] | length')
    echo "available=${available} in-use=${in_use} maintenance=${maintenance} error=${error_count} other=${other}"
}

# Check if a cluster is eligible for this operator
cluster_eligible() {
    local cm="$1"
    local status operators
    status=$(echo "${cm}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    operators=$(echo "${cm}" | jq -r '.metadata.annotations["rosa-cluster-lease/operators"] // ""')

    if [[ -z "${OPERATOR_NAME}" ]]; then
        # Legacy mode: only available clusters
        [[ "${status}" == "available" ]]
        return
    fi

    # Skip clusters in error/provisioning/maintenance
    if [[ "${status}" != "available" && "${status}" != "in-use" ]]; then
        return 1
    fi

    # Skip if this operator is already on this cluster
    if echo ",${operators}," | grep -q ",${OPERATOR_NAME}:"; then
        return 1
    fi

    return 0
}

log "Lease checkout starting"
log "  Type: ${LEASE_TYPE}"
log "  Env: ${LEASE_ENV:-any}"
log "  Region: ${LEASE_REGION:-any}"
log "  Version: ${LEASE_VERSION:-any}"
log "  Operator: ${OPERATOR_NAME:-exclusive}"
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
        TIMEOUT_DIAG=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "${DIAG_SELECTOR}" -o json 2>/dev/null || echo '{"items":[]}')
        TIMEOUT_SUMMARY=$(get_pool_status_summary "${TIMEOUT_DIAG}")
        log "Pool status at timeout: ${TIMEOUT_SUMMARY}"
        log "Selector: ${SELECTOR}"
        if [[ -n "${ARTIFACT_DIR:-}" ]]; then
            echo "${TIMEOUT_DIAG}" > "${ARTIFACT_DIR}/lease-pool-state.json"
        fi
        exit 1
    fi

    REMAINING=$(( (DEADLINE - NOW) / 60 ))
    ATTEMPT=$((ATTEMPT + 1))
    log "Attempt ${ATTEMPT} (${REMAINING}m remaining)"

    CLUSTERS_JSON=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "${SELECTOR}" -o json 2>/dev/null || echo '{"items":[]}')
    TOTAL=$(echo "${CLUSTERS_JSON}" | jq '.items | length')

    # Filter to eligible clusters
    ELIGIBLE=()
    for i in $(seq 0 $((TOTAL - 1))); do
        CM=$(echo "${CLUSTERS_JSON}" | jq ".items[${i}]")
        if cluster_eligible "${CM}"; then
            ELIGIBLE+=("${i}")
        fi
    done
    COUNT=${#ELIGIBLE[@]}

    if [[ "${COUNT}" -eq 0 ]]; then
        if [[ -n "${OPERATOR_NAME}" ]]; then
            log "No eligible clusters (${TOTAL} total, all either have ${OPERATOR_NAME} running or are unhealthy). Waiting 30s..."
        else
            log "No available clusters in lease inventory. Waiting 30s..."
        fi
        DIAG_JSON=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "${DIAG_SELECTOR}" -o json 2>/dev/null || echo '{"items":[]}')
        if [[ "${ATTEMPT}" -eq 1 || $(( ATTEMPT % 10 )) -eq 0 ]]; then
            log_cluster_inventory "${DIAG_JSON}"
        fi
        # Write diagnostic state for machine-parseable diagnostics
        if [[ -n "${ARTIFACT_DIR:-}" ]]; then
            echo "${DIAG_JSON}" > "${ARTIFACT_DIR}/lease-pool-state.json"
        fi
        # Fast-fail: if all clusters are non-recoverable (maintenance/error), exit immediately
        if [[ "${LEASE_FAIL_FAST_ON_EXHAUSTED}" == "true" ]]; then
            POOL_TOTAL=$(echo "${DIAG_JSON}" | jq '.items | length')
            POOL_NONRECOVERABLE=$(echo "${DIAG_JSON}" | jq '[.items[] | select(.metadata.labels["rosa-cluster-lease/status"] == "maintenance" or .metadata.labels["rosa-cluster-lease/status"] == "error")] | length')
            if [[ "${POOL_TOTAL}" -gt 0 && "${POOL_NONRECOVERABLE}" -eq "${POOL_TOTAL}" ]]; then
                POOL_SUMMARY=$(get_pool_status_summary "${DIAG_JSON}")
                log "FATAL: Pool is fully exhausted — all ${POOL_TOTAL} cluster(s) are non-recoverable"
                log "  Pool breakdown: ${POOL_SUMMARY}"
                log "  No clusters will become available without manual intervention."
                log "  Selector: ${DIAG_SELECTOR}"
                exit 1
            fi
        fi
        sleep 30
        continue
    fi

    log "Found ${COUNT} eligible cluster(s) of ${TOTAL} total, attempting claim..."

    CLAIMED=false
    for i in "${ELIGIBLE[@]}"; do
        CM=$(echo "${CLUSTERS_JSON}" | jq ".items[${i}]")
        CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
        CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
        CLUSTER_NAME=$(echo "${CM}" | jq -r '.data["cluster-name"]')

        log "Trying to claim ${CM_NAME} (cluster: ${CLUSTER_ID})..."

        ACQUIRED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        EPOCH=$(date +%s)

        if [[ -n "${OPERATOR_NAME}" ]]; then
            # Per-operator mode: add operator to the operators annotation
            CURRENT_OPS=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/operators"] // ""')
            if [[ -z "${CURRENT_OPS}" ]]; then
                NEW_OPS="${OPERATOR_NAME}:${EPOCH}"
            else
                NEW_OPS="${CURRENT_OPS},${OPERATOR_NAME}:${EPOCH}"
            fi
            MODIFIED=$(echo "${CM}" | jq '
                .metadata.labels["rosa-cluster-lease/status"] = "in-use" |
                .metadata.annotations["rosa-cluster-lease/operators"] = "'"${NEW_OPS}"'" |
                .metadata.annotations["rosa-cluster-lease/holder"] = "'"${JOB_NAME}"'" |
                .metadata.annotations["rosa-cluster-lease/build-id"] = "'"${BUILD_ID}"'" |
                .metadata.annotations["rosa-cluster-lease/acquired-at"] = "'"${ACQUIRED_AT}"'"
            ')
        else
            # Exclusive mode: set status to in-use (legacy behavior)
            MODIFIED=$(echo "${CM}" | jq '
                .metadata.labels["rosa-cluster-lease/status"] = "in-use" |
                .metadata.annotations["rosa-cluster-lease/holder"] = "'"${JOB_NAME}"'" |
                .metadata.annotations["rosa-cluster-lease/build-id"] = "'"${BUILD_ID}"'" |
                .metadata.annotations["rosa-cluster-lease/acquired-at"] = "'"${ACQUIRED_AT}"'"
            ')
        fi

        if echo "${MODIFIED}" | lease_oc replace -n "${LEASE_NAMESPACE}" -f - 2>/dev/null; then
            log "Claimed cluster ${CLUSTER_ID} (${CM_NAME})"
            CLAIMED=true

            echo "${CM_NAME}" > "${SHARED_DIR}/lease-claim"
            echo "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
            echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
            echo "${OPERATOR_NAME}" > "${SHARED_DIR}/lease-operator"

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

    log "All eligible clusters were claimed by other jobs. Waiting 15s..."
    sleep 15
done

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Cluster claimed: ${CLUSTER_ID}"

CLAIMED_OCM_ENV=$(cat "${SHARED_DIR}/ocm-env" 2>/dev/null || true)
LOGIN_ENV="${CLAIMED_OCM_ENV:-${OCM_LOGIN_ENV}}"

# --- OCM authentication ------------------------------------------------
# Report which credential kind was selected, which environment it was offered
# to, how far the step got and with what status. Every value this block prints
# is a fixed string chosen here or a label that passed a strict allowlist, and
# neither the credential nor the provider's response reaches the summary or
# the record it writes. That is a statement about this block only, not about
# the step as a whole, which logs lease and cluster identifiers of its own.
# xtrace, which would echo the credential flags themselves, is not enabled
# anywhere in this script.

# Pass a label through only when it is a short, boring token; anything else is
# reported as a fixed placeholder rather than echoed into the log.
auth_safe_label() {
    local value="${1-}"
    if [[ -z "${value}" ]]; then
        printf '%s' "none"
    elif [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
        printf '%s' "${value}"
    else
        printf '%s' "unsupported"
    fi
}

# The OCM environment is reported by alias only. A deployment may be named by a
# full gateway URL instead, and a URL can carry userinfo, so anything that is
# not a known alias is reported as "other".
case "${LOGIN_ENV}" in
    production|prod|prd|staging|stage|stg|integration|int|local)
        AUTH_ENV_LABEL="${LOGIN_ENV}" ;;
    *)
        AUTH_ENV_LABEL="other" ;;
esac
# The lease consumer: the operator sharing the cluster, or "exclusive" for a
# whole-cluster claim, matching the "Operator" field logged at checkout start.
AUTH_CONSUMER_LABEL=$(auth_safe_label "${OPERATOR_NAME:-exclusive}")
AUTH_PROFILE_LABEL=$(auth_safe_label "${CLUSTER_PROFILE_NAME:-}")

# A machine-readable record of the same safe facts, written on both outcomes
# for a reader who is scanning artifacts rather than the log. Every field is
# an allowlisted label or a value fixed here, so the document needs no
# escaping to stay well formed. The write is best effort: it must never change
# the status the step goes on to report.
auth_artifact() {
    local outcome="$1" stage="$2" status="$3"
    if [[ -z "${ARTIFACT_DIR:-}" ]]; then
        return 0
    fi
    if [[ ! -d "${ARTIFACT_DIR}" ]]; then
        log "WARNING: ARTIFACT_DIR is not a directory, skipping the authentication record"
        return 0
    fi
    if ! cat > "${ARTIFACT_DIR}/lease-checkout-auth.json" <<EOF
{
  "consumer": "${AUTH_CONSUMER_LABEL}",
  "cluster_profile": "${AUTH_PROFILE_LABEL}",
  "auth_mode": "${AUTH_MODE}",
  "environment": "${AUTH_ENV_LABEL}",
  "stage": "${stage}",
  "outcome": "${outcome}",
  "exit_status": ${status}
}
EOF
    then
        log "WARNING: could not write the authentication record to ARTIFACT_DIR"
    fi
    return 0
}

auth_failure() {
    local stage="$1" status="$2"
    log "ERROR: OCM authentication failed"
    log "  Consumer: ${AUTH_CONSUMER_LABEL}"
    log "  Cluster profile: ${AUTH_PROFILE_LABEL}"
    log "  Auth mode: ${AUTH_MODE}"
    log "  Environment: ${AUTH_ENV_LABEL}"
    log "  Stage: ${stage}"
    log "  Exit status: ${status}"
    log "  Provider response withheld: it can echo back credential material."
    auth_artifact failed "${stage}" "${status}"
}

SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

# Unchanged credential selection precedence: SSO client credentials when the
# cluster profile carries both halves, otherwise an offline token.
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    AUTH_MODE="sso-client-credentials"
elif [[ -n "${OCM_TOKEN}" ]]; then
    AUTH_MODE="offline-token"
else
    AUTH_MODE="none"
    log "ERROR: No OCM credentials found in cluster profile"
    auth_failure "credential-selection" 1
    exit 1
fi

log "Logging into OCM ${AUTH_ENV_LABEL} with auth mode ${AUTH_MODE}"
AUTH_STATUS=0
# One attempt, as before: a rejected credential is not retried and no other
# credential is tried after it. The output is discarded rather than logged
# because a failing login can quote the request it was sent back.
if [[ "${AUTH_MODE}" == "sso-client-credentials" ]]; then
    ocm login --url "${LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}" >/dev/null 2>&1 || AUTH_STATUS=$?
elif [[ "${AUTH_MODE}" == "offline-token" ]]; then
    ocm login --url "${LOGIN_ENV}" --token "${OCM_TOKEN}" >/dev/null 2>&1 || AUTH_STATUS=$?
else
    log "ERROR: Unsupported OCM authentication mode"
    auth_failure "credential-selection" 1
    exit 1
fi

if [[ "${AUTH_STATUS}" -ne 0 ]]; then
    auth_failure "ocm-login" "${AUTH_STATUS}"
    exit "${AUTH_STATUS}"
fi

log "Authenticated to OCM ${AUTH_ENV_LABEL} with auth mode ${AUTH_MODE}"
auth_artifact succeeded "ocm-login" 0

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
