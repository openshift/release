#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# ACS OPP Readiness Gate
#
# Verifies that ACS Central and SecuredCluster are operational before
# running SMOKE tests.  Discovers namespaces dynamically via CRs.
# Writes credentials and connection details to $SHARED_DIR for
# downstream steps.
# ---------------------------------------------------------------------------

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

POLL_INTERVAL=30
TIMEOUT=300   # 5 minutes
ELAPSED=0

# ---------------------------------------------------------------------------
# wait_for - retry a check function with backoff until TIMEOUT
# ---------------------------------------------------------------------------
wait_for() {
    local description="$1"
    shift
    local check_fn="$1"
    shift

    ELAPSED=0
    echo "[readiness] Waiting for: ${description}"
    while true; do
        if "${check_fn}" "$@"; then
            echo "[readiness] OK: ${description}"
            return 0
        fi
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
            echo "[readiness] TIMEOUT after ${TIMEOUT}s waiting for: ${description}"
            return 1
        fi
        echo "[readiness]   ...retrying in ${POLL_INTERVAL}s (${ELAPSED}/${TIMEOUT}s)"
        sleep "${POLL_INTERVAL}"
    done
}

# ---------------------------------------------------------------------------
# Namespace discovery via CRs (never hardcode)
# ---------------------------------------------------------------------------
discover_central_ns() {
    CENTRAL_NS="$(oc get centrals.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" \
        && [[ -n "${CENTRAL_NS}" ]]
}

discover_sc_ns() {
    SC_NS="$(oc get securedclusters.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" \
        && [[ -n "${SC_NS}" ]]
}

CENTRAL_NS=""
SC_NS=""

wait_for "Central CR namespace discovery" discover_central_ns
echo "[readiness] Central namespace: ${CENTRAL_NS}"

wait_for "SecuredCluster CR namespace discovery" discover_sc_ns
echo "[readiness] SecuredCluster namespace: ${SC_NS}"

# ---------------------------------------------------------------------------
# Check 1: Central route exists
# ---------------------------------------------------------------------------
check_central_route() {
    oc get route central -n "${CENTRAL_NS}" -o jsonpath='{.spec.host}' >/dev/null 2>&1
}

wait_for "Central route" check_central_route

CENTRAL_URL="$(oc get route central -n "${CENTRAL_NS}" -o jsonpath='{.spec.host}')"
echo "[readiness] Central URL: ${CENTRAL_URL}"

# ---------------------------------------------------------------------------
# Check 2: Central API health (v1/metadata returns 200)
# ---------------------------------------------------------------------------
check_central_api() {
    local http_code
    http_code="$(curl -sk -o /dev/null -w '%{http_code}' \
        "https://${CENTRAL_URL}/v1/metadata" --max-time 10)" || return 1
    [[ "${http_code}" == "200" ]]
}

wait_for "Central API health (v1/metadata)" check_central_api

# ---------------------------------------------------------------------------
# Check 3: At least 1 secured cluster connected
# ---------------------------------------------------------------------------
check_clusters_connected() {
    # Disable xtrace to protect admin password in curl args
    set +x
    local cluster_count
    cluster_count="$(curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" \
        "https://${CENTRAL_URL}/v1/clusters" --max-time 10 \
        | jq '.clusters | length' 2>/dev/null)" || { set -x 2>/dev/null || true; return 1; }
    set -x 2>/dev/null || true
    [[ "${cluster_count}" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# Check 6 (early): Extract ROX_ADMIN_PASSWORD before cluster check
# ---------------------------------------------------------------------------
echo "[readiness] Extracting ROX_ADMIN_PASSWORD..."
ROX_ADMIN_PASSWORD=""
set +x
ROX_ADMIN_PASSWORD="$(oc get secret -n "${CENTRAL_NS}" central-htpasswd \
    -o json | jq -r '.data.password' | base64 -d)"
set -x 2>/dev/null || true

if [[ -z "${ROX_ADMIN_PASSWORD}" ]]; then
    echo "[readiness] FATAL: could not extract ROX_ADMIN_PASSWORD"
    exit 1
fi
echo "[readiness] ROX_ADMIN_PASSWORD extracted successfully"

wait_for "secured cluster connected (v1/clusters)" check_clusters_connected

# ---------------------------------------------------------------------------
# Check 4: Sensor pods Running (detect OOMKilled)
# ---------------------------------------------------------------------------
check_sensor_pods() {
    local pod_json
    pod_json="$(oc get pods -n "${SC_NS}" -l app=sensor -o json 2>/dev/null)"

    local pod_count
    pod_count="$(echo "${pod_json}" | jq '.items | length')"
    if [[ "${pod_count}" -eq 0 ]]; then
        echo "[readiness]   no sensor pods found yet"
        return 1
    fi

    # Check for OOMKilled containers
    local oom
    oom="$(echo "${pod_json}" | jq -r '
        .items[].status.containerStatuses[]?
        | select(.lastState.terminated.reason == "OOMKilled")
        | .name
    ')"
    if [[ -n "${oom}" ]]; then
        echo "[readiness] WARNING: OOMKilled detected in sensor containers: ${oom}"
    fi

    # All sensor pods must be Running
    local not_running
    not_running="$(echo "${pod_json}" | jq -r '
        .items[] | select(.status.phase != "Running")
        | "\(.metadata.name):\(.status.phase)"
    ')"
    [[ -z "${not_running}" ]]
}

wait_for "sensor pods Running in ${SC_NS}" check_sensor_pods

# ---------------------------------------------------------------------------
# Check 5: Default policies loaded (count > 80)
# ---------------------------------------------------------------------------
check_policies_loaded() {
    set +x
    local policy_count
    policy_count="$(curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" \
        "https://${CENTRAL_URL}/v1/policies?query=" --max-time 10 \
        | jq '.policies | length' 2>/dev/null)" || { set -x 2>/dev/null || true; return 1; }
    set -x 2>/dev/null || true
    echo "[readiness]   policy count: ${policy_count}"
    [[ "${policy_count}" -gt 80 ]]
}

wait_for "default policies loaded (>80)" check_policies_loaded

# ---------------------------------------------------------------------------
# Write outputs to SHARED_DIR for downstream steps
# ---------------------------------------------------------------------------
echo "[readiness] Writing connection details to SHARED_DIR..."

set +x
echo "${ROX_ADMIN_PASSWORD}" > "${SHARED_DIR}/ROX_ADMIN_PASSWORD"
set -x 2>/dev/null || true

echo "${CENTRAL_URL}"  > "${SHARED_DIR}/CENTRAL_URL"
echo "${CENTRAL_NS}"   > "${SHARED_DIR}/CENTRAL_NS"
echo "${SC_NS}"        > "${SHARED_DIR}/SC_NS"

echo "[readiness] All checks passed. ACS is ready for SMOKE tests."
