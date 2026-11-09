#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# ACS OPP Readiness Gate (INTEROP-9647 PR-A, team review revision 3 D4-D8)
#
# Verifies that ACS Central and SecuredCluster are operational before
# running SMOKE tests.  Discovers namespaces dynamically via CRs.
# Writes credentials and connection details to $SHARED_DIR for
# downstream steps.
#
# Contract (fail-closed):
#   ACS_EXPECTATION   required | absent-by-design   (unset/other => exit 2)
#   Classification (own query, before any SHARED_DIR consumption):
#     present  - Central CR(s) exist (0-exit oc get, >=1 item)
#     absent   - Central CR list empty on a successful read (0-exit, 0 items)
#     unknown  - read failed after 3 attempts => FAILED, exit != 0
#   Carrier junit lp-interop--OPP--acs-readiness is emitted on EVERY exit
#   path: one classification case (self-describing name), seven assertion
#   cases, one acs-preflight-selftest case.  A hard SIGKILL leaves the
#   pre-seeded failing carrier on disk (never green).
#   Exit codes: 0 pass / absent-by-design; 1 assertion failure or
#   acs-required-but-absent; 2 invalid input; 3 acs-state-indeterminate.
#
# Dependencies: oc, curl, python3 (all present in the `cli` image).
# ---------------------------------------------------------------------------

if [[ -f "${SHARED_DIR:-}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

# --- Env seams (D6) --------------------------------------------------------
ACS_POLL_INTERVAL_S="${ACS_POLL_INTERVAL_S:-30}"
ACS_WAIT_TIMEOUT_S="${ACS_WAIT_TIMEOUT_S:-900}"
ACS_BUDGET_S="${ACS_BUDGET_S:-3300}"
ACS_SELFTEST="${ACS_SELFTEST:-true}"
ACS_EXPECTATION="${ACS_EXPECTATION:-}"
_BUDGET_MARGIN_S=600   # static cross-file check: budget + margin < ref timeout - grace

# Validated and typeset after the carrier/trap machinery is installed, so an
# invalid value produces an InvalidInput carrier case instead of a silent
# arithmetic abort with no carrier (fail-closed).
typeset -i pollInterval=0
typeset -i waitCap=0
typeset -i budget=0

# --- JUnit carrier machinery (deploy-acs precedent, D4/D6) -----------------
_SUITE="lp-interop--OPP--acs-readiness"
_CLASSNAME="lp-interop.OPP.acs-readiness"
_CARRIER="${ARTIFACT_DIR}/junit_${_SUITE}.xml"
_junit_start=$(date +%s)
declare -a _CASES=()
declare -i _N_FAILURES=0 _N_SKIPPED=0 _N_TOTAL=0 _FINALIZED=0
_ACS_STATE="unclassified"
_CLASSIFICATION_CASE=""

_xesc() {
    python3 -c 'import sys, xml.sax.saxutils as x; sys.stdout.write(x.escape(sys.argv[1], {chr(34): "&quot;"}))' "$1"
}

_add_case() {
    # name status(failed|skipped|passed) type message
    typeset name="$1" status="$2" type="${3:-}" msg="${4:-}"
    typeset body=""
    if [[ "${status}" == "failed" ]]; then
        _N_FAILURES+=1
        body="<failure message=\"$(_xesc "${msg}")\" type=\"$(_xesc "${type}")\">$(_xesc "${msg}")</failure>"
    elif [[ "${status}" == "skipped" ]]; then
        _N_SKIPPED+=1
        body="<skipped message=\"$(_xesc "${msg}")\"/>"
    fi
    _CASES+=("<testcase name=\"$(_xesc "${name}")\" classname=\"${_CLASSNAME}\">${body}</testcase>")
    _N_TOTAL+=1
}

_add_classification() {
    # D4: self-describing classification case name
    _CLASSIFICATION_CASE="$1"
    _add_case "$@"
}

_write_carrier() {
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"${_SUITE}\" tests=\"${_N_TOTAL}\" failures=\"${_N_FAILURES}\" errors=\"0\" skipped=\"${_N_SKIPPED}\" time=\"$(( $(date +%s) - _junit_start ))\">"
        typeset c=""
        for c in "${_CASES[@]:-}"; do
            [[ -n "${c}" ]] && echo "  ${c}"
        done
        echo '</testsuite>'
    } > "${_CARRIER}" 2>/dev/null || true
}

_write_shared_copy() {
    # D4 channel split: only the absent-by-design case is downgraded in the
    # SHARED_DIR reporter copy (the PASSED absent-by-design case lives in
    # ${ARTIFACT_DIR} only). A required-but-absent failure is NEVER downgraded:
    # the reporter copy must carry the honest <failure> element.
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit" 2>/dev/null || true
    if [[ "${_ACS_STATE}" == "absent" && "${ACS_EXPECTATION}" == "absent-by-design" ]]; then
        {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo "<testsuite name=\"${_SUITE}\" tests=\"${_N_TOTAL}\" failures=\"${_N_FAILURES}\" errors=\"0\" skipped=\"$(( _N_SKIPPED + 1 ))\" time=\"$(( $(date +%s) - _junit_start ))\">"
            typeset c=""
            for c in "${_CASES[@]:-}"; do
                [[ -n "${c}" ]] || continue
                if [[ "${c}" == *"<testcase name=\"${_CLASSIFICATION_CASE}\""* ]]; then
                    echo "  <testcase name=\"${_CLASSIFICATION_CASE}\" classname=\"${_CLASSNAME}\"><skipped/></testcase>"
                else
                    echo "  ${c}"
                fi
            done
            echo '</testsuite>'
        } > "${SHARED_DIR}/junit/junit_${_SUITE}.xml" 2>/dev/null || true
    else
        cp "${_CARRIER}" "${SHARED_DIR}/junit/" 2>/dev/null || true
    fi
}

_finalize() {
    (( _FINALIZED )) && return 0
    _FINALIZED=1
    _write_carrier
    _write_shared_copy
}

# Pre-seed a default-failing carrier: a hard SIGKILL before classification
# leaves a failing artifact on disk (never green; D6 / 9525 contract).
_ACS_STATE="unknown"
_add_classification "acs-state-indeterminate" failed "PreSeed" "carrier pre-seed: step exited before classification completed (SIGKILL guard)"
_write_carrier
_CASES=()
_N_FAILURES=0 _N_SKIPPED=0 _N_TOTAL=0
_CLASSIFICATION_CASE=""
_ACS_STATE="unclassified"

_terminate() {
    typeset sig="$1"
    if [[ "${_ACS_STATE}" == "unclassified" ]]; then
        _ACS_STATE="unknown"
        _add_classification "acs-state-indeterminate" failed "StepTerminated" "terminated by ${sig} before classification completed"
    else
        _add_case "step-terminated" failed "StepTerminated" "terminated by ${sig} after classification (state=${_ACS_STATE})"
    fi
    exit 143
}
trap '_terminate TERM' TERM
trap '_terminate INT' INT
_jrc=0
trap '_jrc=$?; set +e; set +x; rm -f "${_curlCfg:-}"; if (( _jrc != 0 && _N_FAILURES == 0 )); then _add_case "step-exited-nonzero" failed "StepExit" "step exited ${_jrc} without a recorded failure (state=${_ACS_STATE:-unclassified})"; fi; _finalize; exit "${_jrc}"' EXIT

# ---------------------------------------------------------------------------
# Env-seam validation (fail-closed, unconditional - runs even when
# ACS_SELFTEST=false): a non-positive-integer seam must exit 2 with an
# InvalidInput carrier case, never an arithmetic abort before the carrier
# exists.
# ---------------------------------------------------------------------------
for _seam in ACS_POLL_INTERVAL_S ACS_WAIT_TIMEOUT_S ACS_BUDGET_S; do
    if ! [[ "${!_seam}" =~ ^[1-9][0-9]*$ ]]; then
        _add_case "acs-env-invalid" failed "InvalidInput" \
            "${_seam} must be a positive integer (got: '${!_seam}'); fail-closed"
        echo "[readiness] FATAL: invalid ${_seam}='${!_seam}'"
        exit 2
    fi
done
pollInterval="${ACS_POLL_INTERVAL_S}"
waitCap="${ACS_WAIT_TIMEOUT_S}"
budget="${ACS_BUDGET_S}"
typeset -i _budgetDeadline=$(( $(date +%s) + budget ))

# ---------------------------------------------------------------------------
# Self-test (D6 named executor): machinery validation, always on
# ---------------------------------------------------------------------------
_run_selftest() {
    typeset -i st_rc=0
    [[ -w "${ARTIFACT_DIR}" ]] || { echo "[selftest] FAIL: ARTIFACT_DIR not writable"; st_rc=1; }
    command -v oc >/dev/null 2>&1 || { echo "[selftest] FAIL: oc not found"; st_rc=1; }
    command -v python3 >/dev/null 2>&1 || { echo "[selftest] FAIL: python3 not found"; st_rc=1; }
    command -v curl >/dev/null 2>&1 || { echo "[selftest] FAIL: curl not found"; st_rc=1; }
    [[ "${pollInterval}" -gt 0 ]] || { echo "[selftest] FAIL: ACS_POLL_INTERVAL_S must be > 0"; st_rc=1; }
    [[ "${waitCap}" -gt 0 ]] || { echo "[selftest] FAIL: ACS_WAIT_TIMEOUT_S must be > 0"; st_rc=1; }
    [[ "${budget}" -gt 0 ]] || { echo "[selftest] FAIL: ACS_BUDGET_S must be > 0"; st_rc=1; }
    if (( st_rc == 0 )); then
        _add_case "acs-preflight-selftest" passed
    else
        _add_case "acs-preflight-selftest" failed "SelfTest" "acs-preflight-selftest failed: machinery validation"
    fi
    return "${st_rc}"
}

# ---------------------------------------------------------------------------
# Classification (D4): own query, before any SHARED_DIR consumption
# ---------------------------------------------------------------------------
_classify() {
    typeset out="" items="" attempt="" crdlist=""
    typeset -i rc=0
    for attempt in 1 2 3; do
        # CRD existence first, via a list read that succeeds either way: a
        # missing resource type is a DETERMINISTIC absence (no Central can
        # exist without the CRD), not a transient read failure. This is the
        # 5.x lane reality: no ACS operator is installed, so the centrals
        # query itself errors ("the server doesn't have a resource type") -
        # observed in rehearsal build 2116735878033313792. A successful read
        # with an EMPTY list is the same deterministic absence (the CRD is
        # simply not there), so only the read's success is gated here.
        # Absence classified here is PROVISIONAL on a required lane: the main
        # flow holds it for a bounded window before finalizing (provisional-
        # hold block below), and it is final only for absent-by-design.
        if crdlist="$(oc get crd -o name 2>/dev/null)"; then
            if ! grep -q '^customresourcedefinition\.apiextensions\.k8s\.io/centrals\.platform\.stackrox\.io$' <<< "${crdlist}"; then
                _ACS_STATE="absent"
                return 0
            fi
            if out="$(oc get centrals.platform.stackrox.io -A -o json 2>/dev/null)"; then
                items="$(printf '%s' "${out}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))' 2>/dev/null)" || rc=1
                if (( rc == 0 )); then
                    if (( items > 0 )); then
                        _ACS_STATE="present"
                    else
                        _ACS_STATE="absent"
                    fi
                    return 0
                fi
            fi
        fi
        rc=0
        sleep $(( attempt * 2 ))
    done
    _ACS_STATE="unknown"
    return 0
}

# ---------------------------------------------------------------------------
# Budget-bounded wait (D6): global in-script budget across all waits
# ---------------------------------------------------------------------------
_budget_remaining() {
    typeset -i rem=$(( _budgetDeadline - $(date +%s) ))
    (( rem < 0 )) && rem=0
    echo "${rem}"
}

function WaitFor () {
    typeset description="$1"
    shift
    typeset checkFn="$1"
    shift
    typeset diagnosticsFn="${1:-}"
    if [[ -n "${diagnosticsFn}" ]]; then
        shift
    fi

    typeset -i elapsed=0
    typeset -i iteration=0
    typeset -i cap=waitCap
    typeset -i rem
    rem="$(_budget_remaining)"
    (( rem < cap )) && cap=rem
    if (( cap == 0 )); then
        echo "[readiness] BUDGET EXHAUSTED before waiting for: ${description}"
        return 1
    fi
    echo "[readiness] Waiting for: ${description} (cap ${cap}s, budget remaining $(_budget_remaining)s)"
    while true; do
        if "${checkFn}" "$@"; then
            echo "[readiness] OK: ${description}"
            return 0
        fi
        elapsed=$((elapsed + pollInterval))
        iteration=$((iteration + 1))
        if [[ "${elapsed}" -ge "${cap}" ]]; then
            echo "[readiness] TIMEOUT after ${elapsed}s waiting for: ${description} (budget remaining $(_budget_remaining)s)"
            return 1
        fi
        rem="$(_budget_remaining)"
        if (( rem <= 0 )); then
            echo "[readiness] BUDGET EXHAUSTED while waiting for: ${description}"
            return 1
        fi
        # Every 5th iteration, dump periodic diagnostics if a function is provided
        if [[ -n "${diagnosticsFn}" ]] && (( iteration % 5 == 0 )); then
            echo "[readiness]   --- periodic diagnostics (iteration ${iteration}, ${elapsed}/${cap}s) ---"
            "${diagnosticsFn}" || true
        fi
        echo "[readiness]   ...retrying in ${pollInterval}s (${elapsed}/${cap}s, budget remaining ${rem}s)"
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
# Provisional-hold check (required lanes): succeeds once the Central CRD is
# registered AND at least one Central CR exists. A missing CRD or an empty
# Central list is a deterministic read result, but on a required lane it can
# equally be a race with the step that provisions ACS: the ACM policies that
# install the RHACS operator and create Central are applied by
# acm-policies-openshift-plus but excluded from its policy-compliance wait
# (they are listed in SKIP_POLICIES), so this step can read before Central
# exists. The main flow therefore holds absent provisionally, bounded by
# ACS_WAIT_TIMEOUT_S and the global budget, and finalizes it only when that
# hold expires.
# ---------------------------------------------------------------------------
function CheckCentralPresent () {
    typeset out="" items=""
    oc get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1 || return 1
    out="$(oc get centrals.platform.stackrox.io -A -o json 2>/dev/null)" || return 1
    items="$(printf '%s' "${out}" | JsonLength items)" || return 1
    (( items > 0 ))
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

# Fail-closed expectation validation (D4)
case "${ACS_EXPECTATION}" in
    required|absent-by-design)
        echo "[readiness] ACS_EXPECTATION=${ACS_EXPECTATION}"
        ;;
    *)
        _ACS_STATE="unknown"
        _add_classification "acs-expectation-invalid" failed "InvalidInput" \
            "ACS_EXPECTATION must be 'required' or 'absent-by-design' (got: '${ACS_EXPECTATION:-unset}'); fail-closed"
        echo "[readiness] FATAL: invalid ACS_EXPECTATION '${ACS_EXPECTATION:-unset}'"
        exit 2
        ;;
esac

if [[ "${ACS_SELFTEST}" != "false" ]]; then
    if ! _run_selftest; then
        exit 2
    fi
fi

# Classification before any SHARED_DIR consumption (D4)
_classify
echo "[readiness] ACS state classified: ${_ACS_STATE}"

# Provisional hold on a required lane: a deterministic-absent read must not
# finalize acs-required-but-absent while ACS provisioning may still be in
# flight. Bounded by ACS_WAIT_TIMEOUT_S (further capped by the global budget).
# absent-by-design keeps the immediate verdict and does not wait at all;
# unknown (a failed read) is never held and stays exit 3 below.
if [[ "${_ACS_STATE}" == "absent" && "${ACS_EXPECTATION}" == "required" ]]; then
    echo "[readiness] absent read on a required lane: holding provisionally (cap ${waitCap}s, budget remaining $(_budget_remaining)s)"
    if WaitFor "Central CR present (ACS_EXPECTATION=required)" CheckCentralPresent PeriodicOperatorDiagnostics; then
        _ACS_STATE="present"
        echo "[readiness] ACS state re-classified after provisional hold: ${_ACS_STATE}"
    else
        echo "[readiness] provisional hold expired: finalizing absent"
    fi
fi

if [[ "${_ACS_STATE}" == "unknown" ]]; then
    _add_classification "acs-state-indeterminate" failed "Classification" \
        "acs-unclassified:central-query/read failed after 3 attempts; never classified as absent without a successful read"
    exit 3
fi

if [[ "${_ACS_STATE}" == "absent" ]]; then
    # All seven assertion cases are emitted on every exit path (D4), skipped
    # when the state is absent.
    typeset _a=""
    for _a in central-crd securedcluster-crd central-route central-api-insecure-tls clusters-connected policies-loaded sensor-ready; do
        _add_case "${_a}" skipped "StateAbsent" "state=absent: assertion not evaluated"
    done
    if [[ "${ACS_EXPECTATION}" == "required" ]]; then
        _add_classification "acs-required-but-absent" failed "Classification" \
            "acs-central-not-created: Central CR absent on a successful read while ACS_EXPECTATION=required"
        echo "[readiness] Central CR absent but required by ACS_EXPECTATION"
        exit 1
    fi
    _add_classification "acs-absent-by-design" passed
    echo "[readiness] Central CR absent by design (ACS_EXPECTATION=absent-by-design)"
    exit 0
fi

# --- state=present: run the six assertions ---------------------------------
_add_classification "acs-present" passed
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

typeset -i _assert_rc=0

if oc get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1; then
    _add_case "central-crd" passed
else
    _add_case "central-crd" failed "Assertion" "Central CRD not registered"
    _assert_rc=1
fi

if oc get crd securedclusters.platform.stackrox.io -o name >/dev/null 2>&1; then
    _add_case "securedcluster-crd" passed
else
    _add_case "securedcluster-crd" failed "Assertion" "SecuredCluster CRD not registered"
    _assert_rc=1
fi

if ! WaitFor "Central CR namespace discovery" DiscoverCentralNs PeriodicOperatorDiagnostics; then
    _add_case "central-route" failed "Assertion" "central namespace discovery failed (budget remaining $(_budget_remaining)s)"
    _add_case "central-api-insecure-tls" failed "Assertion" "central namespace discovery failed"
    _add_case "clusters-connected" failed "Assertion" "central namespace discovery failed"
    _add_case "policies-loaded" failed "Assertion" "central namespace discovery failed"
    _add_case "sensor-ready" failed "Assertion" "securedcluster namespace discovery not reached"
    exit 1
fi
echo "[readiness] Central namespace: ${centralNs}"

if ! WaitFor "SecuredCluster CR namespace discovery" DiscoverScNs; then
    _add_case "central-route" skipped "StateAbsent" "securedcluster namespace discovery failed; route check not reached"
    _add_case "central-api-insecure-tls" skipped "StateAbsent" "securedcluster namespace discovery failed"
    _add_case "clusters-connected" skipped "StateAbsent" "securedcluster namespace discovery failed"
    _add_case "policies-loaded" skipped "StateAbsent" "securedcluster namespace discovery failed"
    _add_case "sensor-ready" failed "Assertion" "securedcluster namespace discovery failed (budget remaining $(_budget_remaining)s)"
    exit 1
fi
echo "[readiness] SecuredCluster namespace: ${scNs}"

# ---------------------------------------------------------------------------
# Check: Central route exists
# ---------------------------------------------------------------------------
typeset centralUrl=""

function CheckCentralRoute () {
    centralUrl="$(oc get route central -n "${centralNs}" \
        -o jsonpath='{.spec.host}' 2>/dev/null)" || return 1
    [[ -n "${centralUrl}" ]] || return 1
    true
}

if WaitFor "Central route" CheckCentralRoute; then
    _add_case "central-route" passed
else
    _add_case "central-route" failed "Assertion" "Central route not found in ${centralNs} (budget remaining $(_budget_remaining)s)"
    _assert_rc=1
fi
echo "[readiness] Central route discovered"

# ---------------------------------------------------------------------------
# Credential region (D7): set +x bracket spans every credential
# read/check/use/write below -- no set -x may be active at any of these
# sites (static ordering check enforces this).
# ---------------------------------------------------------------------------
set +x

typeset roxAdminPassword=""
echo "[readiness] Extracting roxAdminPassword..."
roxAdminPassword="$(oc get secret -n "${centralNs}" central-htpasswd \
    -o jsonpath='{.data.password}' | base64 -d)" || true

if [[ -z "${roxAdminPassword}" ]]; then
    echo "[readiness] FATAL: could not extract roxAdminPassword"
    _add_case "central-api-insecure-tls" failed "Assertion" "central-htpasswd secret empty or missing in ${centralNs}"
    _add_case "clusters-connected" skipped "StateAbsent" "no credentials; API checks not reached"
    _add_case "policies-loaded" skipped "StateAbsent" "no credentials; API checks not reached"
    _add_case "sensor-ready" skipped "StateAbsent" "no credentials"
    exit 1
fi

# Credentials go to a curl config file (0600, this step's pod-local
# tmp), never argv: the must-gather sibling step's containment idiom -
# /proc/cmdline never carries the password at any call site below.
_curlCfg="$(mktemp)"
chmod 600 "${_curlCfg}"
# escape for curl config syntax: a password carrying '"' or '' would
# otherwise terminate/alter the quoted token and break authentication
_pwEsc="${roxAdminPassword//\\/\\\\}"
_pwEsc="${_pwEsc//\"/\\\"}"
printf 'user = "admin:%s"\n' "${_pwEsc}" > "${_curlCfg}"
echo "[readiness] roxAdminPassword extracted successfully"

# ---------------------------------------------------------------------------
# Check: Central API health (authenticated v1/metadata; curl -sk — the
# assertion case is named for its mode per D4)
# ---------------------------------------------------------------------------
function CheckCentralApi () {
    typeset httpCode=""
    httpCode="$(curl -sk -o /dev/null -w '%{http_code}' \
        -K "${_curlCfg}" \
        "https://${centralUrl}/v1/metadata" --max-time 10)" || return 1
    [[ "${httpCode}" == "200" ]] || return 1
    true
}

if WaitFor "Central API health (v1/metadata)" CheckCentralApi; then
    _add_case "central-api-insecure-tls" passed
else
    _add_case "central-api-insecure-tls" failed "Assertion" "Central API v1/metadata not healthy (curl -sk, budget remaining $(_budget_remaining)s)"
    _assert_rc=1
fi

# ---------------------------------------------------------------------------
# Check: At least 1 secured cluster connected
# ---------------------------------------------------------------------------
# A /v1/clusters record proves registration, not connection: a sensor that
# never connected reports UNINITIALIZED and a disconnected sensor reports
# UNHEALTHY (fixed ClusterHealthStatus enum in the ACS API, safe to log).
# Count only clusters whose sensor is connected: HEALTHY or DEGRADED.
# Every other value (including UNAVAILABLE, collector-only today) stays
# uncounted so an unexpected value fails closed instead of passing.
function CheckClustersConnected () {
    typeset verdict=""
    verdict="$(curl -sk -K "${_curlCfg}" \
        "https://${centralUrl}/v1/clusters" --max-time 10 \
        | python3 -c '
import json, sys
try:
    clusters = json.load(sys.stdin).get("clusters", [])
except Exception:
    sys.exit(1)
known = ("UNINITIALIZED", "UNAVAILABLE", "UNHEALTHY", "DEGRADED", "HEALTHY")
def norm(c):
    s = ((c.get("healthStatus") or {}).get("sensorHealthStatus") or "UNSET")
    return s if s in known else "OTHER"
states = sorted({norm(c) for c in clusters})
if any(norm(c) in ("HEALTHY", "DEGRADED") for c in clusters):
    print("connected")
else:
    print("waiting:" + (",".join(states) or "noclusters"))
' 2>/dev/null)" || return 1
    if [[ "${verdict}" == connected ]]; then
        return 0
    fi
    echo "[readiness]   no connected sensor yet (sensor states: ${verdict#waiting:})"
    return 1
}

if WaitFor "secured cluster connected (v1/clusters)" CheckClustersConnected; then
    _add_case "clusters-connected" passed
else
    _add_case "clusters-connected" failed "Assertion" "no secured cluster with a connected sensor (v1/clusters) (budget remaining $(_budget_remaining)s)"
    _assert_rc=1
fi

# ---------------------------------------------------------------------------
# Check: Sensor pods Running (detect OOMKilled)
# ---------------------------------------------------------------------------
function CheckSensorPods () {
    # Terminal pods (phase Succeeded/Failed, or already deleting) can never
    # become Ready: a kubelet-evicted sensor pod that is never garbage-
    # collected must not hold the assertion red while its replacement is
    # healthy (observed: evicted sensor pod stuck in phase Failed for the
    # whole run while Central reported the replacement sensor HEALTHY;
    # rehearsal build 2118028576879022080). Only live pods gate readiness.
    typeset sensorStatus=""
    sensorStatus="$(oc get pods -n "${scNs}" -l app=sensor -o json 2>/dev/null | python3 -c '
import json, sys

d = json.load(sys.stdin)
oom = []
live = []
for pod in d.get("items", []):
    meta = pod.get("metadata", {}) or {}
    status = pod.get("status", {}) or {}
    for cs in status.get("containerStatuses", []) or []:
        terminated = (cs.get("lastState", {}) or {}).get("terminated", {})
        if terminated.get("reason") == "OOMKilled":
            oom.append(cs.get("name", "?"))
    if status.get("phase") in ("Succeeded", "Failed") or meta.get("deletionTimestamp") is not None:
        continue
    conditions = {c.get("type"): c.get("status") for c in status.get("conditions", []) or []}
    live.append((meta.get("name", "?"), conditions.get("Ready", "Unknown")))

if oom:
    print("OOMKilled: " + ",".join(sorted(set(oom))))
if not live:
    print("NO_LIVE_PODS")
elif all(ready == "True" for _, ready in live):
    print("ALL_LIVE_READY")
else:
    not_ready = ["%s(Ready=%s)" % (name, ready) for name, ready in live if ready != "True"]
    print("NOT_READY: " + " ".join(not_ready))
' 2>/dev/null)" || return 1
    if printf '%s\n' "${sensorStatus}" | grep -q '^OOMKilled:'; then
        echo "[readiness] WARNING: OOMKilled detected in sensor containers: $(printf '%s\n' "${sensorStatus}" | sed -n 's/^OOMKilled: //p')"
    fi
    if printf '%s\n' "${sensorStatus}" | grep -q '^NO_LIVE_PODS$'; then
        echo "[readiness]   no live sensor pods found yet (terminal pods ignored)"
        return 1
    fi
    typeset notReady=""
    notReady="$(printf '%s\n' "${sensorStatus}" | sed -n 's/^NOT_READY: //p')"
    [[ -z "${notReady}" ]] || { echo "[readiness]   sensor pods not Ready: ${notReady}"; return 1; }
    true
}

if WaitFor "sensor pods Running in ${scNs}" CheckSensorPods; then
    _add_case "sensor-ready" passed
else
    # Name the offending pod(s) in the build log: the retry loop alone only
    # shows counters (observed in rehearsal build 2118028576879022080, where
    # the diagnosis had to come from a later must-gather).
    echo "[readiness] Sensor pod states at timeout:"
    oc get pods -n "${scNs}" -l app=sensor -o wide 2>/dev/null || true
    oc get pods -n "${scNs}" -l app=sensor -o json 2>/dev/null | python3 -c '
import json, sys

d = json.load(sys.stdin)
for pod in d.get("items", []):
    meta = pod.get("metadata", {}) or {}
    status = pod.get("status", {}) or {}
    conditions = {c.get("type"): c.get("status") for c in status.get("conditions", []) or []}
    print("%s phase=%s Ready=%s deletionTimestamp=%s" % (
        meta.get("name", "?"), status.get("phase", "?"),
        conditions.get("Ready", "Unknown"), meta.get("deletionTimestamp")))
' 2>/dev/null || true
    _add_case "sensor-ready" failed "Assertion" "sensor pods not Ready in ${scNs} (budget remaining $(_budget_remaining)s)"
    _assert_rc=1
fi

# ---------------------------------------------------------------------------
# Check: Default policies loaded (count > 80)
# ---------------------------------------------------------------------------
function CheckPoliciesLoaded () {
    typeset policyCount=""
    policyCount="$(curl -sk -K "${_curlCfg}" \
        "https://${centralUrl}/v1/policies?query=" --max-time 10 \
        | JsonLength policies)" || return 1
    echo "[readiness]   policy count: ${policyCount}"
    [[ "${policyCount}" -gt 80 ]] || return 1
    true
}

if WaitFor "default policies loaded (>80)" CheckPoliciesLoaded; then
    _add_case "policies-loaded" passed
else
    _add_case "policies-loaded" failed "Assertion" "default policies not loaded (>80 expected; budget remaining $(_budget_remaining)s)"
    _assert_rc=1
fi

echo "[readiness] Writing connection details to SHARED_DIR..."

echo "${roxAdminPassword}" > "${SHARED_DIR}/ROX_ADMIN_PASSWORD"
echo "${centralUrl}"       > "${SHARED_DIR}/CENTRAL_URL"
echo "${centralNs}"  > "${SHARED_DIR}/CENTRAL_NS"
echo "${scNs}"       > "${SHARED_DIR}/SC_NS"

# End of credential region (D7)
set -x

if (( _assert_rc != 0 )); then
    echo "[readiness] One or more readiness assertions failed; see ${_CARRIER}"
    exit 1
fi
echo "[readiness] All checks passed. ACS is ready for SMOKE tests."
exit 0
