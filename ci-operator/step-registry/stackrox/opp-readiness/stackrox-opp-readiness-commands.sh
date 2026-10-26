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

# Convert resource JSON into fixed labels and numeric counters only. Resource
# identifiers and arbitrary status or condition strings must never be printed.
function FormatDiagnosticStatus () {
    typeset resourceType="$1"
    typeset nameFilter="${2:-}"
    python3 -c '
import json
import sys

resource_type = sys.argv[1]
needles = tuple(part.lower() for part in sys.argv[2].split(",") if part)
try:
    items = json.load(sys.stdin).get("items", [])
except (AttributeError, json.JSONDecodeError):
    sys.exit(1)

def mapping(value):
    return value if isinstance(value, dict) else {}

def status_of(item):
    return mapping(mapping(item).get("status"))

def categorize(values, healthy, progressing, failed):
    counts = {"healthy": 0, "progressing": 0, "failed": 0, "unknown": 0}
    for value in values:
        if isinstance(value, str) and value in healthy:
            counts["healthy"] += 1
        elif isinstance(value, str) and value in progressing:
            counts["progressing"] += 1
        elif isinstance(value, str) and value in failed:
            counts["failed"] += 1
        else:
            counts["unknown"] += 1
    return counts

matched = []
for item in items if isinstance(items, list) else []:
    metadata = mapping(mapping(item).get("metadata"))
    match_values = (str(metadata.get("namespace", "")), str(metadata.get("name", "")))
    if needles and not any(needle in value.lower() for needle in needles for value in match_values):
        continue
    matched.append(mapping(item))

if not matched:
    sys.exit(0)

if resource_type == "subscription":
    counts = categorize(
        (status_of(item).get("state") for item in matched),
        {"AtLatestKnown"},
        {"UpgradeAvailable", "UpgradePending"},
        {"UpgradeFailed"},
    )
    print(
        "resources={} healthy={} progressing={} failed={} unknown={}".format(
            len(matched), counts["healthy"], counts["progressing"], counts["failed"], counts["unknown"]
        )
    )
elif resource_type == "csv":
    counts = categorize(
        (status_of(item).get("phase") for item in matched),
        {"Succeeded"},
        {"Pending", "InstallReady", "Installing", "Replacing", "Deleting"},
        {"Failed"},
    )
    print(
        "resources={} healthy={} progressing={} failed={} unknown={}".format(
            len(matched), counts["healthy"], counts["progressing"], counts["failed"], counts["unknown"]
        )
    )
elif resource_type == "pod":
    counts = {"running": 0, "pending": 0, "failed": 0, "succeeded": 0, "unknown": 0}
    ready = 0
    containers = 0
    restarts = 0
    for item in matched:
        status = status_of(item)
        phase = status.get("phase")
        category = phase.lower() if isinstance(phase, str) and phase in {"Running", "Pending", "Failed", "Succeeded"} else "unknown"
        counts[category] += 1
        container_statuses = status.get("containerStatuses")
        for container in container_statuses if isinstance(container_statuses, list) else []:
            container = mapping(container)
            containers += 1
            ready += int(container.get("ready") is True)
            restart_count = container.get("restartCount", 0)
            restarts += restart_count if isinstance(restart_count, int) and restart_count >= 0 else 0
    print(
        "resources={} running={} pending={} failed={} succeeded={} unknown={} readyContainers={} containers={} restarts={}".format(
            len(matched), counts["running"], counts["pending"], counts["failed"], counts["succeeded"],
            counts["unknown"], ready, containers, restarts
        )
    )
elif resource_type == "installplan":
    counts = categorize(
        (status_of(item).get("phase") for item in matched),
        {"Complete"},
        {"Planning", "RequiresApproval", "Installing"},
        {"Failed"},
    )
    print(
        "resources={} healthy={} progressing={} failed={} unknown={}".format(
            len(matched), counts["healthy"], counts["progressing"], counts["failed"], counts["unknown"]
        )
    )
elif resource_type == "central":
    conditions = []
    for item in matched:
        item_conditions = status_of(item).get("conditions")
        conditions.extend(item_conditions if isinstance(item_conditions, list) else [])
    condition_counts = {"true": 0, "false": 0, "unknown": 0}
    for condition in conditions:
        condition_status = mapping(condition).get("status")
        category = condition_status.lower() if isinstance(condition_status, str) and condition_status in {"True", "False"} else "unknown"
        condition_counts[category] += 1
    print(
        "resources={} conditions={} true={} false={} unknown={}".format(
            len(matched), len(conditions), condition_counts["true"], condition_counts["false"],
            condition_counts["unknown"]
        )
    )
else:
    sys.exit(1)
' "${resourceType}" "${nameFilter}" 2>/dev/null
}

# Summarize matching operator Subscriptions, falling back on empty selectors.
function SubscriptionStatus () {
    typeset output=""
    if output="$(oc get sub -A -l 'operators.coreos.com/rhacs-operator.rhacs-operator' -o json 2>/dev/null \
        | FormatDiagnosticStatus subscription)" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    if output="$(oc get sub -A -o json 2>/dev/null \
        | FormatDiagnosticStatus subscription 'stackrox,rhacs')" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    return 1
}

# Summarize StackRox/RHACS CSV state without printing CSV identifiers.
function CsvStatus () {
    typeset output=""
    output="$(oc get csv -A -o json 2>/dev/null \
        | FormatDiagnosticStatus csv 'stackrox,rhacs')" && [[ -n "${output}" ]] || return 1
    echo "${output}"
}

# Summarize matching operator pods, falling back on empty selectors.
function OperatorPodStatus () {
    typeset output=""
    if output="$(oc get pods -A -l app=rhacs-operator -o json 2>/dev/null \
        | FormatDiagnosticStatus pod)" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    if output="$(oc get pods -A -o json 2>/dev/null \
        | FormatDiagnosticStatus pod rhacs)" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    return 1
}

# Summarize StackRox/RHACS InstallPlan state without printing identifiers.
function InstallPlanStatus () {
    typeset output=""
    output="$(oc get installplan -A -o json 2>/dev/null \
        | FormatDiagnosticStatus installplan 'stackrox,rhacs')" && [[ -n "${output}" ]] || return 1
    echo "${output}"
}

# Summarize Central conditions without printing condition content.
function CentralStatus () {
    typeset output=""
    output="$(oc get centrals.platform.stackrox.io -A -o json 2>/dev/null \
        | FormatDiagnosticStatus central)" && [[ -n "${output}" ]] || return 1
    echo "${output}"
}

# ---------------------------------------------------------------------------
# Pre-flight diagnostics: inspect operator state BEFORE CR discovery
# ---------------------------------------------------------------------------
function PreFlightDiagnostics () {
    echo "[readiness] === Pre-flight operator diagnostics ==="

    echo "[readiness] Checking Central CRD registration..."
    if oc get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1; then
        echo "[readiness]   Central CRD registered"
    else
        echo "[readiness]   Central CRD NOT found"
    fi

    echo "[readiness] Checking SecuredCluster CRD registration..."
    if oc get crd securedclusters.platform.stackrox.io -o name >/dev/null 2>&1; then
        echo "[readiness]   SecuredCluster CRD registered"
    else
        echo "[readiness]   SecuredCluster CRD NOT found"
    fi

    echo "[readiness] StackRox/RHACS operator Subscription status..."
    SubscriptionStatus || echo "[readiness]   No StackRox/RHACS subscription found"

    echo "[readiness] StackRox/RHACS operator CSV status..."
    CsvStatus || echo "[readiness]   No StackRox/RHACS CSV found"

    echo "[readiness] StackRox/RHACS operator pod status..."
    OperatorPodStatus || echo "[readiness]   No RHACS operator pods found"

    echo "[readiness] === End pre-flight diagnostics ==="
}

# ---------------------------------------------------------------------------
# Periodic diagnostics: brief operator status during Central CR polling
# ---------------------------------------------------------------------------
function PeriodicOperatorDiagnostics () {
    echo "[readiness]   Subscription status:"
    SubscriptionStatus || echo "[readiness]     (none)"
    echo "[readiness]   CSV status:"
    CsvStatus || echo "[readiness]     (none)"
    echo "[readiness]   Operator pods:"
    OperatorPodStatus || echo "[readiness]     (none)"
    echo "[readiness]   Central CRs (any state):"
    CentralStatus || echo "[readiness]     (none)"
}

# ---------------------------------------------------------------------------
# Failure diagnostics: allowlisted operator status on discovery timeout
# ---------------------------------------------------------------------------
function CentralDiscoveryFailureDiagnostics () {
    echo "[readiness] === Failure diagnostics ==="

    echo "[readiness] --- StackRox/RHACS Subscriptions ---"
    SubscriptionStatus || echo "[readiness]   (none)"

    echo "[readiness] --- StackRox/RHACS CSVs ---"
    CsvStatus || echo "[readiness]   (none)"

    echo "[readiness] --- StackRox/RHACS operator pods ---"
    OperatorPodStatus || echo "[readiness]   (none)"

    echo "[readiness] --- InstallPlans ---"
    InstallPlanStatus || echo "[readiness]   (none)"

    echo "[readiness] --- Central CRs in any state ---"
    CentralStatus || echo "[readiness]   No Central CRs found at all"

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
