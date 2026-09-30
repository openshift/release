#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# ACS OPP Readiness Gate
#
# Verifies that ACS Central and SecuredCluster are operational before
# running SMOKE tests.  Discovers namespaces dynamically via CRs.
# Writes credentials and connection details to $SHARED_DIR for
# downstream steps.
#
# Dependencies: oc, curl, python3 (all present in the `cli` image).
# ---------------------------------------------------------------------------

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

typeset -i pollInterval=30
typeset -i timeout=900
typeset -i elapsed=0
typeset -i iteration=0

function WaitFor () {
    typeset description="$1"
    shift
    typeset checkFn="$1"
    shift
    typeset diagnosticsFn="${1:-}"
    if [[ -n "${diagnosticsFn}" ]]; then
        shift
    fi

    elapsed=0
    iteration=0
    echo "[readiness] Waiting for: ${description}"
    while true; do
        if "${checkFn}" "$@"; then
            echo "[readiness] OK: ${description}"
            return 0
        fi
        elapsed=$((elapsed + pollInterval))
        iteration=$((iteration + 1))
        if [[ "${elapsed}" -ge "${timeout}" ]]; then
            echo "[readiness] TIMEOUT after ${timeout}s waiting for: ${description}"
            return 1
        fi
        # Every 5th iteration, dump periodic diagnostics if a function is provided
        if [[ -n "${diagnosticsFn}" ]] && (( iteration % 5 == 0 )); then
            echo "[readiness]   --- periodic diagnostics (iteration ${iteration}, ${elapsed}/${timeout}s) ---"
            "${diagnosticsFn}" || true
        fi
        echo "[readiness]   ...retrying in ${pollInterval}s (${elapsed}/${timeout}s)"
        sleep "${pollInterval}"
    done
    true
}

function JsonLength () {
    python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('$1',[])))" || return 1
    true
}

# ---------------------------------------------------------------------------
# Pre-flight diagnostics: inspect operator state BEFORE CR discovery
# ---------------------------------------------------------------------------
function PreFlightDiagnostics () {
    echo "[readiness] === Pre-flight operator diagnostics ==="

    echo "[readiness] Checking Central CRD registration..."
    oc get crd centrals.platform.stackrox.io 2>&1 || echo "[readiness]   Central CRD NOT found"

    echo "[readiness] Checking SecuredCluster CRD registration..."
    oc get crd securedclusters.platform.stackrox.io 2>&1 || echo "[readiness]   SecuredCluster CRD NOT found"

    echo "[readiness] StackRox/RHACS operator Subscription status..."
    oc get sub -A -l 'operators.coreos.com/rhacs-operator.rhacs-operator' 2>&1 \
        || oc get sub -A 2>/dev/null | grep -i -e stackrox -e rhacs || echo "[readiness]   No StackRox/RHACS subscription found"

    echo "[readiness] StackRox/RHACS operator CSV status..."
    oc get csv -A 2>/dev/null | grep -i -e stackrox -e rhacs || echo "[readiness]   No StackRox/RHACS CSV found"

    echo "[readiness] StackRox/RHACS operator pod status..."
    oc get pods -A -l app=rhacs-operator 2>&1 \
        || oc get pods -A 2>/dev/null | grep -i rhacs || echo "[readiness]   No RHACS operator pods found"

    echo "[readiness] === End pre-flight diagnostics ==="
}

# ---------------------------------------------------------------------------
# Periodic diagnostics: brief operator status during Central CR polling
# ---------------------------------------------------------------------------
function PeriodicOperatorDiagnostics () {
    echo "[readiness]   Subscription status:"
    oc get sub -A 2>/dev/null | grep -i -e stackrox -e rhacs || echo "[readiness]     (none)"
    echo "[readiness]   CSV status:"
    oc get csv -A 2>/dev/null | grep -i -e stackrox -e rhacs || echo "[readiness]     (none)"
    echo "[readiness]   Operator pods:"
    oc get pods -A -l app=rhacs-operator --no-headers 2>/dev/null \
        || oc get pods -A --no-headers 2>/dev/null | grep -i rhacs || echo "[readiness]     (none)"
    echo "[readiness]   Central CRs (any state):"
    oc get centrals.platform.stackrox.io -A 2>/dev/null || echo "[readiness]     (none)"
}

# ---------------------------------------------------------------------------
# Comprehensive failure diagnostics: run on Central CR discovery timeout
# ---------------------------------------------------------------------------
function CentralDiscoveryFailureDiagnostics () {
    echo "[readiness] === Comprehensive failure diagnostics ==="

    echo "[readiness] --- StackRox/RHACS Subscriptions ---"
    oc get sub -A -o wide 2>/dev/null | grep -i -e stackrox -e rhacs || echo "[readiness]   (none)"

    echo "[readiness] --- StackRox/RHACS CSVs (with conditions) ---"
    oc get csv -A -o wide 2>/dev/null | grep -i -e stackrox -e rhacs || echo "[readiness]   (none)"
    # Describe CSVs for condition details
    for csv_info in $(oc get csv -A --no-headers 2>/dev/null | grep -i -e stackrox -e rhacs | awk '{print $1 "/" $2}'); do
        typeset csv_ns="${csv_info%%/*}"
        typeset csv_name="${csv_info#*/}"
        echo "[readiness]   CSV ${csv_name} conditions:"
        oc get csv "${csv_name}" -n "${csv_ns}" -o jsonpath='{range .status.conditions[*]}  {.type}={.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
    done

    echo "[readiness] --- StackRox/RHACS operator pod logs (last 50 lines) ---"
    for pod_info in $(oc get pods -A -l app=rhacs-operator --no-headers 2>/dev/null | awk '{print $1 "/" $2}'); do
        typeset pod_ns="${pod_info%%/*}"
        typeset pod_name="${pod_info#*/}"
        echo "[readiness]   Logs from ${pod_ns}/${pod_name}:"
        oc logs "${pod_name}" -n "${pod_ns}" --tail=50 2>&1 || true
    done

    echo "[readiness] --- InstallPlans ---"
    oc get installplan -A 2>/dev/null | grep -i -e stackrox -e rhacs || echo "[readiness]   (none)"

    echo "[readiness] --- Events in stackrox/rhacs namespaces ---"
    for ns in $(oc get namespaces --no-headers 2>/dev/null | awk '{print $1}' | grep -i -e stackrox -e rhacs); do
        echo "[readiness]   Events in namespace ${ns}:"
        oc get events -n "${ns}" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
    done

    echo "[readiness] --- Central CRs in any state ---"
    oc get centrals.platform.stackrox.io -A -o wide 2>/dev/null || echo "[readiness]   No Central CRs found at all"

    echo "[readiness] === End failure diagnostics ==="
}

PreFlightDiagnostics

# ---------------------------------------------------------------------------
# Namespace discovery via CRs (never hardcode)
# ---------------------------------------------------------------------------
function DiscoverCentralNs () {
    centralNs="$(oc get centrals.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" \
        || return 1
    [[ -n "${centralNs}" ]] || return 1
    true
}

function DiscoverScNs () {
    scNs="$(oc get securedclusters.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" \
        || return 1
    [[ -n "${scNs}" ]] || return 1
    true
}

typeset centralNs=""
typeset scNs=""

if ! WaitFor "Central CR namespace discovery" DiscoverCentralNs PeriodicOperatorDiagnostics; then
    CentralDiscoveryFailureDiagnostics
    exit 1
fi
echo "[readiness] Central namespace: ${centralNs}"

WaitFor "SecuredCluster CR namespace discovery" DiscoverScNs
echo "[readiness] SecuredCluster namespace: ${scNs}"

# ---------------------------------------------------------------------------
# Check 1: Central route exists
# ---------------------------------------------------------------------------
typeset centralUrl=""

function CheckCentralRoute () {
    centralUrl="$(oc get route central -n "${centralNs}" \
        -o jsonpath='{.spec.host}' 2>/dev/null)" || return 1
    [[ -n "${centralUrl}" ]] || return 1
    true
}

WaitFor "Central route" CheckCentralRoute
echo "[readiness] Central route discovered"

# ---------------------------------------------------------------------------
# Extract ROX_ADMIN_PASSWORD before API checks
# ---------------------------------------------------------------------------
typeset roxAdminPassword=""
echo "[readiness] Extracting roxAdminPassword..."
roxAdminPassword="$(oc get secret -n "${centralNs}" central-htpasswd \
    -o jsonpath='{.data.password}' | base64 -d)"

if [[ -z "${roxAdminPassword}" ]]; then
    echo "[readiness] FATAL: could not extract roxAdminPassword"
    exit 1
fi
echo "[readiness] roxAdminPassword extracted successfully"

# ---------------------------------------------------------------------------
# Check 2: Central API health (authenticated v1/metadata)
# ---------------------------------------------------------------------------
function CheckCentralApi () {
    typeset httpCode=""
    httpCode="$(curl -sk -o /dev/null -w '%{http_code}' \
        -u "admin:${roxAdminPassword}" \
        "https://${centralUrl}/v1/metadata" --max-time 10)" || return 1
    [[ "${httpCode}" == "200" ]] || return 1
    true
}

WaitFor "Central API health (v1/metadata)" CheckCentralApi

# ---------------------------------------------------------------------------
# Check 3: At least 1 secured cluster connected
# ---------------------------------------------------------------------------
function CheckClustersConnected () {
    typeset clusterCount=""
    clusterCount="$(curl -sk -u "admin:${roxAdminPassword}" \
        "https://${centralUrl}/v1/clusters" --max-time 10 \
        | JsonLength clusters)" || return 1
    [[ "${clusterCount}" -ge 1 ]] || return 1
    true
}

WaitFor "secured cluster connected (v1/clusters)" CheckClustersConnected

# ---------------------------------------------------------------------------
# Check 4: Sensor pods Running (detect OOMKilled)
# ---------------------------------------------------------------------------
function CheckSensorPods () {
    typeset podCount=""
    podCount="$(oc get pods -n "${scNs}" -l app=sensor \
        -o json 2>/dev/null | JsonLength items)" || return 1
    if [[ "${podCount}" -eq 0 ]]; then
        echo "[readiness]   no sensor pods found yet"
        return 1
    fi

    typeset sensorJson=""
    sensorJson="$(oc get pods -n "${scNs}" -l app=sensor -o json 2>/dev/null)" || return 1
    typeset oomContainers=""
    if [[ -n "${sensorJson}" ]]; then
        oomContainers="$(echo "${sensorJson}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for pod in d.get('items',[]):
    for cs in pod.get('status',{}).get('containerStatuses',[]):
        ls=cs.get('lastState',{}).get('terminated',{})
        if ls.get('reason')=='OOMKilled':
            print(cs['name'])
")"
    fi
    if [[ -n "${oomContainers}" ]]; then
        echo "[readiness] WARNING: OOMKilled detected in sensor containers: ${oomContainers}"
    fi

    typeset podConditions=""
    podConditions="$(oc get pods -n "${scNs}" -l app=sensor \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' 2>/dev/null)" || return 1
    typeset notReady=""
    notReady="$(echo "${podConditions}" | while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            if ! echo "${line}" | grep -q 'Ready=True'; then
                echo "${line%% *}:NotReady"
            fi
        done)"
    [[ -z "${notReady}" ]] || return 1
    true
}

WaitFor "sensor pods Running in ${scNs}" CheckSensorPods

# ---------------------------------------------------------------------------
# Check 5: Default policies loaded (count > 80)
# ---------------------------------------------------------------------------
function CheckPoliciesLoaded () {
    typeset policyCount=""
    policyCount="$(curl -sk -u "admin:${roxAdminPassword}" \
        "https://${centralUrl}/v1/policies?query=" --max-time 10 \
        | JsonLength policies)" || return 1
    echo "[readiness]   policy count: ${policyCount}"
    [[ "${policyCount}" -gt 80 ]] || return 1
    true
}

WaitFor "default policies loaded (>80)" CheckPoliciesLoaded

echo "[readiness] Writing connection details to SHARED_DIR..."

echo "${roxAdminPassword}" > "${SHARED_DIR}/ROX_ADMIN_PASSWORD"
echo "${centralUrl}"       > "${SHARED_DIR}/CENTRAL_URL"

echo "${centralNs}"  > "${SHARED_DIR}/CENTRAL_NS"
echo "${scNs}"       > "${SHARED_DIR}/SC_NS"

echo "[readiness] All checks passed. ACS is ready for SMOKE tests."
true
