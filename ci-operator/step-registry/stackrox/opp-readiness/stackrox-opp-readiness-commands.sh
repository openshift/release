#!/bin/bash
set -eux -o pipefail

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
TIMEOUT=600
ELAPSED=0

# ---------------------------------------------------------------------------
# WaitFor - retry a check function with backoff until TIMEOUT
# ---------------------------------------------------------------------------
function WaitFor () {
    typeset description="$1"
    shift
    typeset checkFn="$1"
    shift

    ELAPSED=0
    echo "[readiness] Waiting for: ${description}"
    while true; do
        if "${checkFn}" "$@"; then
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
    true
}

# ---------------------------------------------------------------------------
# Namespace discovery via CRs (never hardcode)
# ---------------------------------------------------------------------------
function DiscoverCentralNs () {
    CENTRAL_NS="$(oc get centrals.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" \
        && [[ -n "${CENTRAL_NS}" ]]
}

function DiscoverScNs () {
    SC_NS="$(oc get securedclusters.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" \
        && [[ -n "${SC_NS}" ]]
}

CENTRAL_NS=""
SC_NS=""

WaitFor "Central CR namespace discovery" DiscoverCentralNs
echo "[readiness] Central namespace discovered"

WaitFor "SecuredCluster CR namespace discovery" DiscoverScNs
echo "[readiness] SecuredCluster namespace discovered"

# ---------------------------------------------------------------------------
# Check 1: Central route exists
# ---------------------------------------------------------------------------
function CheckCentralRoute () {
    oc get route central -n "${CENTRAL_NS}" -o jsonpath='{.spec.host}' >/dev/null 2>&1
}

WaitFor "Central route" CheckCentralRoute

set +x
CENTRAL_URL="$(oc get route central -n "${CENTRAL_NS}" -o jsonpath='{.spec.host}')"
set -x
echo "[readiness] Central route discovered"

# ---------------------------------------------------------------------------
# Check 2: Central API health (v1/metadata returns 200)
# ---------------------------------------------------------------------------
function CheckCentralApi () {
    set +x
    typeset httpCode=""
    httpCode="$(curl -sk -o /dev/null -w '%{http_code}' \
        "https://${CENTRAL_URL}/v1/metadata" --max-time 10)" || { set -x; return 1; }
    set -x
    [[ "${httpCode}" == "200" ]]
}

WaitFor "Central API health (v1/metadata)" CheckCentralApi

# ---------------------------------------------------------------------------
# Check 3: At least 1 secured cluster connected
# ---------------------------------------------------------------------------
function CheckClustersConnected () {
    set +x
    typeset clusterCount=""
    clusterCount="$(curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" \
        "https://${CENTRAL_URL}/v1/clusters" --max-time 10 \
        | jq '.clusters | length' 2>/dev/null)" || { set -x; return 1; }
    set -x
    [[ "${clusterCount}" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# Extract ROX_ADMIN_PASSWORD before cluster check
# ---------------------------------------------------------------------------
echo "[readiness] Extracting ROX_ADMIN_PASSWORD..."
ROX_ADMIN_PASSWORD=""
set +x
ROX_ADMIN_PASSWORD="$(oc get secret -n "${CENTRAL_NS}" central-htpasswd \
    -o json | jq -r '.data.password' | base64 -d)"
set -x

if [[ -z "${ROX_ADMIN_PASSWORD}" ]]; then
    echo "[readiness] FATAL: could not extract ROX_ADMIN_PASSWORD"
    exit 1
fi
echo "[readiness] ROX_ADMIN_PASSWORD extracted successfully"

WaitFor "secured cluster connected (v1/clusters)" CheckClustersConnected

# ---------------------------------------------------------------------------
# Check 4: Sensor pods Running (detect OOMKilled)
# ---------------------------------------------------------------------------
function CheckSensorPods () {
    typeset podJson=""
    podJson="$(oc get pods -n "${SC_NS}" -l app=sensor -o json 2>/dev/null)"

    typeset podCount=""
    podCount="$(echo "${podJson}" | jq '.items | length')"
    if [[ "${podCount}" -eq 0 ]]; then
        echo "[readiness]   no sensor pods found yet"
        return 1
    fi

    typeset oom=""
    oom="$(echo "${podJson}" | jq -r '
        .items[].status.containerStatuses[]?
        | select(.lastState.terminated.reason == "OOMKilled")
        | .name
    ')"
    if [[ -n "${oom}" ]]; then
        echo "[readiness] WARNING: OOMKilled detected in sensor containers: ${oom}"
    fi

    typeset notReady=""
    notReady="$(echo "${podJson}" | jq -r '
        .items[]
        | select(
            [.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0
        )
        | "\(.metadata.name):NotReady"
    ')"
    [[ -z "${notReady}" ]]
}

WaitFor "sensor pods Running in ${SC_NS}" CheckSensorPods

# ---------------------------------------------------------------------------
# Check 5: Default policies loaded (count > 80)
# ---------------------------------------------------------------------------
function CheckPoliciesLoaded () {
    set +x
    typeset policyCount=""
    policyCount="$(curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" \
        "https://${CENTRAL_URL}/v1/policies?query=" --max-time 10 \
        | jq '.policies | length' 2>/dev/null)" || { set -x; return 1; }
    set -x
    echo "[readiness]   policy count: ${policyCount}"
    [[ "${policyCount}" -gt 80 ]]
}

WaitFor "default policies loaded (>80)" CheckPoliciesLoaded

# ---------------------------------------------------------------------------
# Write outputs to SHARED_DIR for downstream steps
# ---------------------------------------------------------------------------
echo "[readiness] Writing connection details to SHARED_DIR..."

set +x
echo "${ROX_ADMIN_PASSWORD}" > "${SHARED_DIR}/ROX_ADMIN_PASSWORD"
set -x

echo "${CENTRAL_URL}"  > "${SHARED_DIR}/CENTRAL_URL"
echo "${CENTRAL_NS}"   > "${SHARED_DIR}/CENTRAL_NS"
echo "${SC_NS}"        > "${SHARED_DIR}/SC_NS"

echo "[readiness] All checks passed. ACS is ready for SMOKE tests."
