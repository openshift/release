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
#   INTEROP__OPP__ACS__EXPECTATION   required | absent-by-design   (unset/other => exit 2)
#   Classification (own query, before any SHARED_DIR consumption):
#     present  - Central CR(s) exist (0-exit oc get, >=1 item)
#     absent   - Central CR list empty on a successful read (0-exit, 0 items)
#     unknown  - read failed after 3 attempts => FAILED, exit != 0
#   Carrier junit lp-interop--OPP--stackrox-opp-readiness is emitted on EVERY exit
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
# Step-config-declared variables (CIOP-4 double-underscore names). Values live
# only in the step ref YAML (CIOP-5.3: no script-side defaults).
# No `:?` unset-guards here: an abort at this point exits with status 1 before
# the carrier and EXIT trap exist, skipping the documented InvalidInput case and
# exit 2. Every seam is normalized to the empty string instead, so the
# validators below the trap own the exit-2 verdict for unset, empty, and
# malformed values alike (SELFTEST's ref default is a non-empty "true"; a `:?`
# there would only mask the same early-abort hole).
INTEROP__OPP__ACS__POLL_INTERVAL_S="${INTEROP__OPP__ACS__POLL_INTERVAL_S:-}"
INTEROP__OPP__ACS__WAIT_TIMEOUT_S="${INTEROP__OPP__ACS__WAIT_TIMEOUT_S:-}"
INTEROP__OPP__ACS__BUDGET_S="${INTEROP__OPP__ACS__BUDGET_S:-}"
INTEROP__OPP__ACS__SELFTEST="${INTEROP__OPP__ACS__SELFTEST:-}"
INTEROP__OPP__ACS__EXPECTATION="${INTEROP__OPP__ACS__EXPECTATION:-}"
_BUDGET_MARGIN_S=600   # static cross-file check: budget + margin < ref timeout - grace

# Validated and typeset after the carrier/trap machinery is installed, so an
# invalid value produces an InvalidInput carrier case instead of a silent
# arithmetic abort with no carrier (fail-closed).
typeset -i pollInterval=0
typeset -i waitCap=0
typeset -i budget=0

# --- JUnit carrier machinery (deploy-acs precedent, D4/D6) -----------------
_SUITE="lp-interop--OPP--stackrox-opp-readiness"
_CLASSNAME="stackrox-opp-readiness"
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
    typeset _tmp="${_CARRIER}.tmp"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"${_SUITE}\" tests=\"${_N_TOTAL}\" failures=\"${_N_FAILURES}\" errors=\"0\" skipped=\"${_N_SKIPPED}\" time=\"$(( $(date +%s) - _junit_start ))\">"
        typeset c=""
        for c in "${_CASES[@]:-}"; do
            [[ -n "${c}" ]] && echo "  ${c}"
        done
        echo '</testsuite>'
    } > "${_tmp}" 2>>"${ARTIFACT_DIR}/junit-write.err" || return 1
    mv -f "${_tmp}" "${_CARRIER}" 2>>"${ARTIFACT_DIR}/junit-write.err" || return 1
}

_write_shared_copy() {
    # D4 channel split: only the absent-by-design case is downgraded in the
    # SHARED_DIR reporter copy (the PASSED absent-by-design case lives in
    # ${ARTIFACT_DIR} only). A required-but-absent failure is NEVER downgraded:
    # the reporter copy must carry the honest <failure> element.
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit" 2>/dev/null || return 1
    typeset _dst="${SHARED_DIR}/junit/junit_${_SUITE}.xml"
    typeset _tmp="${_dst}.tmp"
    if [[ "${_ACS_STATE}" == "absent" && "${INTEROP__OPP__ACS__EXPECTATION}" == "absent-by-design" ]]; then
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
        } > "${_tmp}" 2>>"${ARTIFACT_DIR}/junit-write.err" || return 1
        mv -f "${_tmp}" "${_dst}" 2>>"${ARTIFACT_DIR}/junit-write.err" || return 1
    else
        {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo "<testsuite name=\"${_SUITE}\" tests=\"${_N_TOTAL}\" failures=\"${_N_FAILURES}\" errors=\"0\" skipped=\"${_N_SKIPPED}\" time=\"$(( $(date +%s) - _junit_start ))\">"
            typeset c=""
            for c in "${_CASES[@]:-}"; do
                [[ -n "${c}" ]] && echo "  ${c}"
            done
            echo '</testsuite>'
        } > "${_tmp}" 2>>"${ARTIFACT_DIR}/junit-write.err" || return 1
        mv -f "${_tmp}" "${_dst}" 2>>"${ARTIFACT_DIR}/junit-write.err" || return 1
    fi
}

_finalize() {
    (( _FINALIZED )) && return 0
    _FINALIZED=1
    typeset -i _fin=0
    if ! _write_carrier; then
        _fin=1
        if (( _N_FAILURES == 0 )); then
            _add_case "junit-publication" failed "Propagation" "failed to finalize JUnit carrier"
        fi
    fi
    if ! _write_shared_copy; then
        _fin=1
        if (( _N_FAILURES == 0 )); then
            _add_case "junit-publication" failed "Propagation" "failed to finalize JUnit carrier"
        fi
        _write_carrier 2>/dev/null || true
    fi
    return "${_fin}"
}

_ensure_assertion_rows() {
    typeset _a="" _c="" _found=0
    typeset _need_selftest=1
    for _c in "${_CASES[@]:-}"; do
        if [[ "${_c}" == *"<testcase name=\"acs-preflight-selftest\""* ]]; then
            _need_selftest=0
            break
        fi
    done
    if (( _need_selftest )); then
        _add_case "acs-preflight-selftest" skipped "NotEvaluated" "selftest not evaluated (early exit)"
    fi
    for _a in central-crd securedcluster-crd central-route central-api-insecure-tls clusters-connected policies-loaded sensor-ready; do
        _found=0
        for _c in "${_CASES[@]:-}"; do
            if [[ "${_c}" == *"<testcase name=\"${_a}\""* ]]; then
                _found=1
                break
            fi
        done
        if (( _found == 0 )); then
            _add_case "${_a}" skipped "NotEvaluated" "assertion not evaluated (early exit, state=${_ACS_STATE:-unclassified})"
        fi
    done
}

# Pre-seed a default-failing carrier: a hard SIGKILL before classification
# leaves a failing artifact on disk (never green; D6 / 9525 contract).
_ACS_STATE="unknown"
_add_classification "acs-state-indeterminate" failed "PreSeed" "carrier pre-seed: step exited before classification completed (SIGKILL guard)"
_write_carrier || { echo "[readiness] WARN: carrier pre-seed write failed" >&2; true; }
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
        if [[ -z "${_CLASSIFICATION_CASE}" ]]; then
            _add_classification "acs-state-indeterminate" failed "StepTerminated" "terminated by ${sig} during provisional hold (state=${_ACS_STATE})"
            _ACS_STATE="unknown"
        fi
        _add_case "step-terminated" failed "StepTerminated" "terminated by ${sig} after classification (state=${_ACS_STATE})"
    fi
    exit 143
}
trap '_terminate TERM' TERM
trap '_terminate INT' INT
_jrc=0
trap '_jrc=$?; set +e; set +x; rm -f "${_curlCfg:-}"; _ensure_assertion_rows; if (( _jrc != 0 && _N_FAILURES == 0 )); then _add_case "step-exited-nonzero" failed "StepExit" "step exited ${_jrc} without a recorded failure (state=${_ACS_STATE:-unclassified})"; fi; typeset -i _fin_rc=0; _finalize || _fin_rc=1; if (( _fin_rc != 0 )); then if (( _jrc == 0 )); then _jrc=1; fi; fi; if (( _N_FAILURES > 0 && _jrc == 0 )); then _jrc=1; fi; exit "${_jrc}"' EXIT

# ---------------------------------------------------------------------------
# Env-seam validation (fail-closed, unconditional - runs even when
# INTEROP__OPP__ACS__SELFTEST=false): a non-positive-integer seam must exit 2 with an
# InvalidInput carrier case, never an arithmetic abort before the carrier
# exists.
# ---------------------------------------------------------------------------
# `${!_seam}` reads the value unguarded only after the `:-` normalization
# above, so an unset variable cannot trip `set -u` and skip the carrier case.
for _seam in INTEROP__OPP__ACS__POLL_INTERVAL_S INTEROP__OPP__ACS__WAIT_TIMEOUT_S INTEROP__OPP__ACS__BUDGET_S; do
    if ! [[ "${!_seam}" =~ ^[1-9][0-9]*$ ]]; then
        _add_classification "acs-env-invalid" failed "InvalidInput" \
            "${_seam} must be a positive integer (got: '${!_seam}'); fail-closed"
        _ensure_assertion_rows
        echo "[readiness] FATAL: invalid ${_seam}='${!_seam}'"
        exit 2
    fi
done
# SELFTEST is a boolean switch: anything other than true/false is invalid input,
# judged here so the verdict is the documented exit 2 with an InvalidInput case
# rather than a silent interpretation of a typo as "run the self-test".
if [[ "${INTEROP__OPP__ACS__SELFTEST}" != "true" && "${INTEROP__OPP__ACS__SELFTEST}" != "false" ]]; then
    _add_classification "acs-env-invalid" failed "InvalidInput" \
        "INTEROP__OPP__ACS__SELFTEST must be 'true' or 'false' (got: '${INTEROP__OPP__ACS__SELFTEST}'); fail-closed"
    _ensure_assertion_rows
    echo "[readiness] FATAL: invalid INTEROP__OPP__ACS__SELFTEST='${INTEROP__OPP__ACS__SELFTEST}'"
    exit 2
fi
pollInterval="${INTEROP__OPP__ACS__POLL_INTERVAL_S}"
waitCap="${INTEROP__OPP__ACS__WAIT_TIMEOUT_S}"
budget="${INTEROP__OPP__ACS__BUDGET_S}"
typeset -i _budgetDeadline=$(( $(date +%s) + budget ))
# Wait outcome exported by WaitFor for JUnit messages (cap=min(waitCap, budget remaining))
typeset -i _waitCap=0
typeset _waitReason=""

# ---------------------------------------------------------------------------
# Self-test (D6 named executor): machinery validation, always on
# ---------------------------------------------------------------------------
_discovery_wait_message() {
    # Build JUnit message for SecuredCluster discovery failure, distinguishing
    # budget exhaustion from an expired discovery wait and reporting the
    # effective wait cap actually used.
    typeset suffix="$1"
    typeset msg=""
    if [[ "${_waitReason}" == budget-exhausted* ]]; then
        msg="SecuredCluster discovery budget exhausted (cap ${_waitCap}s): ${suffix} (budget remaining $(_budget_remaining)s)"
    else
        msg="SecuredCluster discovery timeout after ${_waitCap}s: ${suffix} (budget remaining $(_budget_remaining)s)"
    fi
    printf '%s' "${msg}"
}

_run_selftest() {
    typeset -i st_rc=0
    [[ -w "${ARTIFACT_DIR}" ]] || { echo "[selftest] FAIL: ARTIFACT_DIR not writable"; st_rc=1; }
    command -v oc >/dev/null 2>&1 || { echo "[selftest] FAIL: oc not found"; st_rc=1; }
    command -v python3 >/dev/null 2>&1 || { echo "[selftest] FAIL: python3 not found"; st_rc=1; }
    command -v curl >/dev/null 2>&1 || { echo "[selftest] FAIL: curl not found"; st_rc=1; }
    [[ "${pollInterval}" -gt 0 ]] || { echo "[selftest] FAIL: INTEROP__OPP__ACS__POLL_INTERVAL_S must be > 0"; st_rc=1; }
    [[ "${waitCap}" -gt 0 ]] || { echo "[selftest] FAIL: INTEROP__OPP__ACS__WAIT_TIMEOUT_S must be > 0"; st_rc=1; }
    [[ "${budget}" -gt 0 ]] || { echo "[selftest] FAIL: INTEROP__OPP__ACS__BUDGET_S must be > 0"; st_rc=1; }
    # Discovery wait message selftest: verify both budget-exhausted and timeout
    # paths and a shortened effective cap are reported in JUnit messages.
    if (( st_rc == 0 )); then
        typeset -i _savedWaitCap="${waitCap}"
        typeset -i _savedPollInterval="${pollInterval}"
        typeset -i _savedBudgetDeadline="${_budgetDeadline}"
        # Use a shortened cap and fast poll for the selftest probes
        pollInterval=1
        waitCap=3
        _budgetDeadline=$(( $(date +%s) + 60 ))
        # Probe that always fails, to exercise the timeout path
        _selftest_probe_fail() { return 1; }
        _waitCap=0; _waitReason=""
        WaitFor "selftest discovery timeout" _selftest_probe_fail >/dev/null 2>&1 || true
        typeset _msg=""
        _msg="$(_discovery_wait_message "no SecuredCluster CR found while INTEROP__OPP__ACS__EXPECTATION=required")"
        if [[ "${_msg}" != *"timeout after 3s"* ]]; then
            echo "[selftest] FAIL: discovery timeout message should report effective cap 3s, got: ${_msg}" >&2
            st_rc=1
        fi
        if [[ "${_msg}" == *"budget exhausted"* ]]; then
            echo "[selftest] FAIL: timeout path should not report budget exhausted, got: ${_msg}" >&2
            st_rc=1
        fi
        if [[ "${_msg}" == *"900s"* ]]; then
            echo "[selftest] FAIL: discovery message should not hardcode 900s, got: ${_msg}" >&2
            st_rc=1
        fi
        # Probe the budget-exhausted path by setting budget deadline in the past
        _budgetDeadline=$(( $(date +%s) - 1 ))
        _waitCap=0; _waitReason=""
        WaitFor "selftest budget exhausted" _selftest_probe_fail >/dev/null 2>&1 || true
        _msg="$(_discovery_wait_message "securedcluster namespace discovery failed")"
        if [[ "${_msg}" != *"budget exhausted"* ]]; then
            echo "[selftest] FAIL: budget exhausted path should report budget exhausted, got: ${_msg}" >&2
            st_rc=1
        fi
        if [[ "${_msg}" == *"900s"* ]]; then
            echo "[selftest] FAIL: budget exhausted message should not hardcode 900s, got: ${_msg}" >&2
            st_rc=1
        fi
        # Verify both list outcomes produce distinguishable JUnit messages
        _budgetDeadline=$(( $(date +%s) + 60 ))
        waitCap=2
        _waitCap=0; _waitReason=""
        WaitFor "selftest zero-result path" _selftest_probe_fail >/dev/null 2>&1 || true
        typeset _zeroMsg=""
        _zeroMsg="$(_discovery_wait_message "no SecuredCluster CR found while INTEROP__OPP__ACS__EXPECTATION=required")"
        _budgetDeadline=$(( $(date +%s) - 1 ))
        _waitCap=0; _waitReason=""
        WaitFor "selftest failed-read path" _selftest_probe_fail >/dev/null 2>&1 || true
        typeset _failMsg=""
        _failMsg="$(_discovery_wait_message "securedcluster namespace discovery failed")"
        if [[ "${_zeroMsg}" == "${_failMsg}" ]]; then
            echo "[selftest] FAIL: zero-result and failed-read messages should be distinct" >&2
            st_rc=1
        fi
        if [[ "${_zeroMsg}" != *"2s"* && "${_zeroMsg}" != *"cap 2s"* ]]; then
            echo "[selftest] FAIL: shortened cap 2s should appear in zero-result message, got: ${_zeroMsg}" >&2
            st_rc=1
        fi
        # Probe the budget-limited path: a positive budget shorter than waitCap
        # expires during the wait, so the message must report budget exhaustion
        # rather than a discovery timeout.
        waitCap=30
        _budgetDeadline=$(( $(date +%s) + 2 ))
        _waitCap=0; _waitReason=""
        WaitFor "selftest budget-limited wait" _selftest_probe_fail >/dev/null 2>&1 || true
        typeset _limitedMsg=""
        _limitedMsg="$(_discovery_wait_message "no SecuredCluster CR found while INTEROP__OPP__ACS__EXPECTATION=required")"
        if [[ "${_limitedMsg}" != *"budget exhausted"* ]]; then
            echo "[selftest] FAIL: budget-limited wait should report budget exhausted, got: ${_limitedMsg}" >&2
            st_rc=1
        fi
        if [[ "${_limitedMsg}" == *"discovery timeout"* ]]; then
            echo "[selftest] FAIL: budget-limited wait should not report discovery timeout, got: ${_limitedMsg}" >&2
            st_rc=1
        fi
        # Restore original values
        waitCap="${_savedWaitCap}"
        pollInterval="${_savedPollInterval}"
        _budgetDeadline="${_savedBudgetDeadline}"
        _waitCap=0; _waitReason=""
        unset -f _selftest_probe_fail 2>/dev/null || true
    fi
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
    typeset _traceWasOff=0
    [[ $- == *x* ]] || _traceWasOff=1
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
        set +x
        if crdlist="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd -o name)"; then
            if ! grep -q '^customresourcedefinition\.apiextensions\.k8s\.io/centrals\.platform\.stackrox\.io$' <<< "${crdlist}"; then
                _ACS_STATE="absent"
                (( _traceWasOff == 0 )) && set -x
                return 0
            fi
            if out="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get centrals.platform.stackrox.io -A -o json)"; then
                set +x
                items="$(printf '%s' "${out}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))')" || rc=1
                set +x
                if (( rc == 0 )); then
                    if (( items > 0 )); then
                        _ACS_STATE="present"
                    else
                        _ACS_STATE="absent"
                    fi
                    (( _traceWasOff == 0 )) && set -x
                    return 0
                fi
            fi
        fi
        (( _traceWasOff == 0 )) && set -x
        rc=0
        sleep $(( attempt * 2 ))
    done
    (( _traceWasOff == 0 )) && set -x
    _ACS_STATE="unknown"
    return 0
}

# ---------------------------------------------------------------------------
# Budget-bounded wait (D6): global in-script budget across all waits.
# Every read a check callback makes carries --request-timeout (OC_READ_TIMEOUT,
# default 10s): the budget is only re-evaluated after a call returns, so an
# unbounded read could overrun the cap it is meant to respect.
# ---------------------------------------------------------------------------
_budget_remaining() {
    typeset -i rem=$(( _budgetDeadline - $(date +%s) ))
    (( rem < 0 )) && rem=0
    echo "${rem}"
}

# Per-call read timeout clamped to the remaining global budget. The budget is
# only re-evaluated after a call returns, so a read bounded only by
# OC_READ_TIMEOUT (10s default) can overrun the deadline it is meant to respect.
# Used by reads that run outside the WaitFor loop (the provisional-hold
# recheck), where the loop's own remaining-budget arithmetic does not apply.
_read_timeout_arg() {
    typeset _base="${OC_READ_TIMEOUT:-10s}"
    typeset -i _base_s="${_base%s}" _rem
    (( _base_s > 0 )) || _base_s=10
    _rem="$(_budget_remaining)"
    (( _rem < 1 )) && _rem=1
    (( _base_s > _rem )) && _base_s=_rem
    echo "${_base_s}s"
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

    typeset -i iteration=0
    typeset -i cap=waitCap
    typeset -i rem
    rem="$(_budget_remaining)"
    (( rem < cap )) && cap=rem
    _waitCap="${cap}"
    _waitReason=""
    # A cap below waitCap means the global budget, not the wait cap, bounds this
    # wait: deadline expiry is then budget exhaustion, not a discovery timeout.
    typeset _deadlineReason="timeout"
    (( cap < waitCap )) && _deadlineReason="budget-exhausted-deadline"
    if (( cap == 0 )); then
        _waitReason="budget-exhausted-before"
        echo "[readiness] BUDGET EXHAUSTED before waiting for: ${description}"
        return 1
    fi
    typeset -i _deadline=$(( $(date +%s) + cap ))
    echo "[readiness] Waiting for: ${description} (cap ${cap}s, budget remaining $(_budget_remaining)s)"
    while true; do
        typeset -i _now=0
        _now=$(date +%s)
        if (( _now >= _deadline )); then
            _waitReason="${_deadlineReason}"
            echo "[readiness] TIMEOUT after $(( _now - (_deadline - cap) ))s waiting for: ${description} (budget remaining $(_budget_remaining)s)"
            return 1
        fi
        if "${checkFn}" "$@"; then
            _now=$(date +%s)
            if (( _now >= _deadline )); then
                _waitReason="${_deadlineReason}"
                echo "[readiness] TIMEOUT after $(( _now - (_deadline - cap) ))s waiting for: ${description} (post-deadline probe success not accepted, budget remaining $(_budget_remaining)s)"
                return 1
            fi
            echo "[readiness] OK: ${description}"
            return 0
        fi
        _now=$(date +%s)
        if (( _now >= _deadline )); then
            _waitReason="${_deadlineReason}"
            echo "[readiness] TIMEOUT after $(( _now - (_deadline - cap) ))s waiting for: ${description} (budget remaining $(_budget_remaining)s)"
            return 1
        fi
        rem="$(_budget_remaining)"
        if (( rem <= 0 )); then
            _waitReason="budget-exhausted-while"
            echo "[readiness] BUDGET EXHAUSTED while waiting for: ${description}"
            return 1
        fi
        typeset -i _remain=$(( _deadline - _now ))
        (( _remain > rem )) && _remain=rem
        typeset -i _sleepFor=$(( _remain < pollInterval ? _remain : pollInterval ))
        if (( _remain <= pollInterval )); then
            _sleepFor=$(( _remain - 1 ))
        fi
        iteration=$((iteration + 1))
        # Every 5th iteration, dump periodic diagnostics if a function is provided
        if [[ -n "${diagnosticsFn}" ]] && (( iteration % 5 == 0 )); then
            echo "[readiness]   --- periodic diagnostics (iteration ${iteration}, $(( _now - (_deadline - cap) ))/${cap}s) ---"
            "${diagnosticsFn}" || true
            _now=$(date +%s)
            if (( _now >= _deadline )); then
                _waitReason="${_deadlineReason}"
                echo "[readiness] TIMEOUT after $(( _now - (_deadline - cap) ))s waiting for: ${description} (budget remaining $(_budget_remaining)s)"
                return 1
            fi
            rem="$(_budget_remaining)"
            if (( rem <= 0 )); then
                _waitReason="budget-exhausted-while"
                echo "[readiness] BUDGET EXHAUSTED while waiting for: ${description}"
                return 1
            fi
            _remain=$(( _deadline - _now ))
            (( _remain > rem )) && _remain=rem
            _sleepFor=$(( _remain < pollInterval ? _remain : pollInterval ))
            if (( _remain <= pollInterval )); then
                _sleepFor=$(( _remain - 1 ))
            fi
        fi
        echo "[readiness]   ...retrying in ${_sleepFor}s ($(( _now - (_deadline - cap) ))/${cap}s, budget remaining ${rem}s)"
        sleep "${_sleepFor}"
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
' "${resourceType}" "${nameFilter}"
}

# Summarize matching operator Subscriptions, falling back on empty selectors.
function SubscriptionStatus () {
    typeset output=""
    if output="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get sub -A -l 'operators.coreos.com/rhacs-operator.rhacs-operator' -o json \
        | FormatDiagnosticStatus subscription)" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    if output="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get sub -A -o json \
        | FormatDiagnosticStatus subscription 'stackrox,rhacs')" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    return 1
}

# Summarize StackRox/RHACS CSV state without printing CSV identifiers.
function CsvStatus () {
    typeset output=""
    output="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get csv -A -o json \
        | FormatDiagnosticStatus csv 'stackrox,rhacs')" && [[ -n "${output}" ]] || return 1
    echo "${output}"
}

# Summarize matching operator pods, falling back on empty selectors.
function OperatorPodStatus () {
    typeset output=""
    if output="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get pods -A -l app=rhacs-operator -o json \
        | FormatDiagnosticStatus pod)" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    if output="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get pods -A -o json \
        | FormatDiagnosticStatus pod rhacs)" && [[ -n "${output}" ]]; then
        echo "${output}"
        return 0
    fi
    return 1
}

# Summarize StackRox/RHACS InstallPlan state without printing identifiers.
function InstallPlanStatus () {
    typeset output=""
    output="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get installplan -A -o json \
        | FormatDiagnosticStatus installplan 'stackrox,rhacs')" && [[ -n "${output}" ]] || return 1
    echo "${output}"
}

# Summarize Central conditions without printing condition content.
function CentralStatus () {
    typeset output=""
    output="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get centrals.platform.stackrox.io -A -o json \
        | FormatDiagnosticStatus central)" && [[ -n "${output}" ]] || return 1
    echo "${output}"
}

# ---------------------------------------------------------------------------
# Pre-flight diagnostics: inspect operator state BEFORE CR discovery
# ---------------------------------------------------------------------------
function PreFlightDiagnostics () {
    echo "[readiness] === Pre-flight operator diagnostics ==="

    echo "[readiness] Checking Central CRD registration..."
    if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1; then
        echo "[readiness]   Central CRD registered"
    else
        echo "[readiness]   Central CRD NOT found"
    fi

    echo "[readiness] Checking SecuredCluster CRD registration..."
    if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd securedclusters.platform.stackrox.io -o name >/dev/null 2>&1; then
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
# INTEROP__OPP__ACS__WAIT_TIMEOUT_S and the global budget, and finalizes it only when that
# hold expires.
# ---------------------------------------------------------------------------
typeset -i _centralPresentHadSuccess=0
# Per-call request timeout for the hold check's reads: the default unless the
# provisional-hold recheck clamps it to the remaining budget.
typeset _ccpReadTimeout="${OC_READ_TIMEOUT:-10s}"
function CheckCentralPresent () {
    typeset out="" items="" crdlist=""
    typeset _traceWasOff=0
    [[ $- == *x* ]] || _traceWasOff=1
    set +x
    if ! crdlist="$(oc --request-timeout="${_ccpReadTimeout}" get crd -o name)"; then
        (( _traceWasOff == 0 )) && set -x
        return 2
    fi
    if ! grep -q '^customresourcedefinition\.apiextensions\.k8s\.io/centrals\.platform\.stackrox\.io$' <<< "${crdlist}"; then
        _centralPresentHadSuccess=1
        (( _traceWasOff == 0 )) && set -x
        return 1
    fi
    if ! out="$(oc --request-timeout="${_ccpReadTimeout}" get centrals.platform.stackrox.io -A -o json)"; then
        (( _traceWasOff == 0 )) && set -x
        return 2
    fi
    items="$(printf '%s' "${out}" | JsonLength items)" || { (( _traceWasOff == 0 )) && set -x; return 2; }
    _centralPresentHadSuccess=1
    (( _traceWasOff == 0 )) && set -x
    (( items > 0 ))
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

# Fail-closed expectation validation (D4)
case "${INTEROP__OPP__ACS__EXPECTATION}" in
    required|absent-by-design)
        echo "[readiness] INTEROP__OPP__ACS__EXPECTATION=${INTEROP__OPP__ACS__EXPECTATION}"
        ;;
    *)
        _ACS_STATE="unknown"
        _add_classification "acs-expectation-invalid" failed "InvalidInput" \
            "INTEROP__OPP__ACS__EXPECTATION must be 'required' or 'absent-by-design' (got: '${INTEROP__OPP__ACS__EXPECTATION:-unset}'); fail-closed"
        _ensure_assertion_rows
        echo "[readiness] FATAL: invalid INTEROP__OPP__ACS__EXPECTATION '${INTEROP__OPP__ACS__EXPECTATION:-unset}'"
        exit 2
        ;;
esac

if [[ "${INTEROP__OPP__ACS__SELFTEST}" != "false" ]]; then
    if ! _run_selftest; then
        if [[ -z "${_CLASSIFICATION_CASE}" ]]; then
            _add_classification "acs-selftest-failed" failed "SelfTest" "acs-preflight-selftest failed: machinery validation"
        fi
        _ensure_assertion_rows
        exit 2
    fi
fi

# Classification before any SHARED_DIR consumption (D4)
_classify
echo "[readiness] ACS state classified: ${_ACS_STATE}"

# Provisional hold on a required lane: a deterministic-absent read must not
# finalize acs-required-but-absent while ACS provisioning may still be in
# flight. Bounded by INTEROP__OPP__ACS__WAIT_TIMEOUT_S (further capped by the global budget).
# absent-by-design keeps the immediate verdict and does not wait at all;
# unknown (a failed read) is never held and stays exit 3 below.
if [[ "${_ACS_STATE}" == "absent" && "${INTEROP__OPP__ACS__EXPECTATION}" == "required" ]]; then
    echo "[readiness] absent read on a required lane: holding provisionally (cap ${waitCap}s, budget remaining $(_budget_remaining)s)"
    _centralPresentHadSuccess=0
    if WaitFor "Central CR present (INTEROP__OPP__ACS__EXPECTATION=required)" CheckCentralPresent PeriodicOperatorDiagnostics; then
        _ACS_STATE="present"
        echo "[readiness] ACS state re-classified after provisional hold: ${_ACS_STATE}"
    else
        if (( _centralPresentHadSuccess == 0 )); then
            echo "[readiness] provisional hold: no successful read, failing indeterminate" >&2
            _ACS_STATE="unknown"
            _add_classification "acs-state-indeterminate" failed "Classification" "acs-unclassified:central-query/read failed during provisional hold; never classified as absent without a successful read"
            exit 3
        fi
        typeset -i _recheck_budget
        _recheck_budget="$(_budget_remaining)"
        if (( _recheck_budget == 0 )); then
            echo "[readiness] provisional hold recheck: budget exhausted, failing indeterminate" >&2
            _ACS_STATE="unknown"
            _add_classification "acs-state-indeterminate" failed "Classification" "acs-unclassified:central-query/read failed during provisional hold recheck; never classified as absent without a successful read"
            _ensure_assertion_rows
            exit 3
        fi
        # Bound the recheck reads by what is left of the budget (each read would
        # otherwise be free to take the full OC_READ_TIMEOUT past the deadline).
        # A read that starts inside the budget and succeeds just after the
        # deadline is still accepted: finalizing absent on a Central that was
        # arriving is the exact failure this hold exists to prevent, and
        # _BUDGET_MARGIN_S absorbs the overrun.
        _ccpReadTimeout="$(_read_timeout_arg)"
        typeset -i _recheck_rc=0
        if CheckCentralPresent; then
            _recheck_rc=0
        else
            _recheck_rc=$?
        fi
        _ccpReadTimeout="${OC_READ_TIMEOUT:-10s}"
        if (( _recheck_rc == 0 )); then
            _ACS_STATE="present"
            echo "[readiness] ACS state re-classified after provisional hold (late success): ${_ACS_STATE}"
        elif (( _recheck_rc == 2 )); then
            echo "[readiness] provisional hold recheck: read failed, failing indeterminate" >&2
            _ACS_STATE="unknown"
            _add_classification "acs-state-indeterminate" failed "Classification" "acs-unclassified:central-query/read failed during provisional hold recheck; never classified as absent without a successful read"
            _ensure_assertion_rows
            exit 3
        else
            echo "[readiness] provisional hold expired: finalizing absent"
        fi
    fi
fi

if [[ "${_ACS_STATE}" == "unknown" ]]; then
    _add_classification "acs-state-indeterminate" failed "Classification" \
        "acs-unclassified:central-query/read failed after 3 attempts; never classified as absent without a successful read"
    _ensure_assertion_rows
    exit 3
fi

if [[ "${_ACS_STATE}" == "absent" ]]; then
    # All seven assertion cases are emitted on every exit path (D4), skipped
    # when the state is absent.
    typeset _a=""
    for _a in central-crd securedcluster-crd central-route central-api-insecure-tls clusters-connected policies-loaded sensor-ready; do
        _add_case "${_a}" skipped "StateAbsent" "state=absent: assertion not evaluated"
    done
    if [[ "${INTEROP__OPP__ACS__EXPECTATION}" == "required" ]]; then
        _add_classification "acs-required-but-absent" failed "Classification" \
            "acs-central-not-created: Central CR absent on a successful read while INTEROP__OPP__ACS__EXPECTATION=required"
        echo "[readiness] Central CR absent but required by INTEROP__OPP__ACS__EXPECTATION"
        exit 1
    fi
    _add_classification "acs-absent-by-design" passed
    echo "[readiness] Central CR absent by design (INTEROP__OPP__ACS__EXPECTATION=absent-by-design)"
    exit 0
fi

# --- state=present: run the six assertions ---------------------------------
_add_classification "acs-present" passed
PreFlightDiagnostics

# ---------------------------------------------------------------------------
# Namespace discovery via CRs (never hardcode)
# ---------------------------------------------------------------------------
function DiscoverCentralNs () {
    centralNs="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get centrals.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}')" \
        || return 1
    [[ -n "${centralNs}" ]] || return 1
    true
}

function DiscoverScNs () {
    scNs="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get securedclusters.platform.stackrox.io --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}')" \
        || return 1
    [[ -n "${scNs}" ]] || return 1
    true
}

typeset centralNs=""
typeset scNs=""

typeset -i _assert_rc=0
typeset -i _centralCrdInitiallyOk=0 _scCrdInitiallyOk=0
if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1; then
    _centralCrdInitiallyOk=1
fi
if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd securedclusters.platform.stackrox.io -o name >/dev/null 2>&1; then
    _scCrdInitiallyOk=1
fi

if ! WaitFor "Central CR namespace discovery" DiscoverCentralNs PeriodicOperatorDiagnostics; then
    if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1; then
        _add_case "central-crd" passed
    else
        _add_case "central-crd" failed "Assertion" "Central CRD not registered"
        _assert_rc=1
    fi
    if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd securedclusters.platform.stackrox.io -o name >/dev/null 2>&1; then
        _add_case "securedcluster-crd" passed
    else
        _add_case "securedcluster-crd" failed "Assertion" "SecuredCluster CRD not registered"
        _assert_rc=1
    fi
    _add_case "central-route" failed "Assertion" "central namespace discovery failed (budget remaining $(_budget_remaining)s)"
    _add_case "central-api-insecure-tls" failed "Assertion" "central namespace discovery failed"
    _add_case "clusters-connected" failed "Assertion" "central namespace discovery failed"
    _add_case "policies-loaded" failed "Assertion" "central namespace discovery failed"
    _add_case "sensor-ready" failed "Assertion" "securedcluster namespace discovery not reached"
    exit 1
fi
echo "[readiness] Central namespace: ${centralNs}"

# Terminal-state wait for SecuredCluster CR: the previous oc wait --for=create
# with --all never waited on kubectl v1.31 (an empty list visits nothing), and a
# separate existence poll would duplicate the namespace-discovery wait below;
# the WaitFor DiscoverScNs call is the real bounded existence wait.
if ! WaitFor "SecuredCluster CR namespace discovery" DiscoverScNs; then
    # Emit deferred CRD cases before handling discovery failure
    if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1; then
        _add_case "central-crd" passed
    else
        _add_case "central-crd" failed "Assertion" "Central CRD not registered"
        _assert_rc=1
    fi
    if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd securedclusters.platform.stackrox.io -o name >/dev/null 2>&1; then
        _add_case "securedcluster-crd" passed
    else
        _add_case "securedcluster-crd" failed "Assertion" "SecuredCluster CRD not registered"
        _assert_rc=1
    fi
    # DiscoverScNs fails both for a failed read and for a 0-exit read that
    # yields no namespace: only the second is an absent workload. Re-read once
    # to separate them, so an API error or an authorization denial stays a
    # failure instead of a silent skip.
    typeset _scList=""
    if _scList="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get securedclusters.platform.stackrox.io --all-namespaces -o name)" \
        && [[ -z "${_scList}" ]]; then
        _add_case "central-route" skipped "NoSecuredCluster" "no SecuredCluster in lane: central-route not evaluated (budget remaining $(_budget_remaining)s)"
        _add_case "central-api-insecure-tls" skipped "NoSecuredCluster" "no SecuredCluster in lane: central-api not evaluated (budget remaining $(_budget_remaining)s)"
        _add_case "clusters-connected" skipped "NoSecuredCluster" "no SecuredCluster in lane: clusters-connected not evaluated"
        _add_case "policies-loaded" skipped "NoSecuredCluster" "no SecuredCluster in lane: policies-loaded not evaluated"
        _add_case "sensor-ready" skipped "NoSecuredCluster" "no SecuredCluster in lane: sensor-ready not evaluated (budget remaining $(_budget_remaining)s)"
        if [[ "${INTEROP__OPP__ACS__EXPECTATION}" == "required" ]]; then _add_case "securedcluster-discovery" failed "Discovery" "$(_discovery_wait_message "no SecuredCluster CR found while INTEROP__OPP__ACS__EXPECTATION=required")"; _add_case "stackrox-opp-readiness" failed "Discovery" "SecuredCluster discovery failed while INTEROP__OPP__ACS__EXPECTATION=required (budget remaining $(_budget_remaining)s)"; exit 1; fi
        if (( _assert_rc != 0 )); then _add_case "stackrox-opp-readiness" failed "Assertion" "earlier assertion failed and SecuredCluster workload is absent (budget remaining $(_budget_remaining)s)"; exit 1; fi
        _add_case "stackrox-opp-readiness" skipped "NoSecuredCluster" "no SecuredCluster in lane: readiness assertions not evaluated (budget remaining $(_budget_remaining)s)"
        exit 0
    fi
    _add_case "central-route" skipped "StateAbsent" "securedcluster namespace discovery failed; route check not reached"
    _add_case "central-api-insecure-tls" skipped "StateAbsent" "securedcluster namespace discovery failed"
    _add_case "clusters-connected" skipped "StateAbsent" "securedcluster namespace discovery failed"
    _add_case "policies-loaded" skipped "StateAbsent" "securedcluster namespace discovery failed"
    _add_case "sensor-ready" failed "Assertion" "securedcluster namespace discovery failed (budget remaining $(_budget_remaining)s)"
    _add_case "stackrox-opp-readiness" failed "Timeout" "$(_discovery_wait_message "securedcluster namespace discovery failed")"
    exit 1
fi
echo "[readiness] SecuredCluster namespace: ${scNs}"
# Emit deferred CRD assertions after successful discovery, re-checking late registration
if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd centrals.platform.stackrox.io -o name >/dev/null 2>&1; then
    _add_case "central-crd" passed
else
    _add_case "central-crd" failed "Assertion" "Central CRD not registered"
    _assert_rc=1
fi
if oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd securedclusters.platform.stackrox.io -o name >/dev/null 2>&1; then
    _add_case "securedcluster-crd" passed
else
    _add_case "securedcluster-crd" failed "Assertion" "SecuredCluster CRD not registered"
    _assert_rc=1
fi

# ---------------------------------------------------------------------------
# Check: Central route exists
# ---------------------------------------------------------------------------
typeset centralUrl=""

function CheckCentralRoute () {
    centralUrl="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get route central -n "${centralNs}" \
        -o jsonpath='{.spec.host}')" || return 1
    [[ -n "${centralUrl}" ]] || return 1
    true
}

if WaitFor "Central route" CheckCentralRoute; then
    _add_case "central-route" passed
    echo "[readiness] Central route discovered: ${centralUrl}"
else
    centralUrl=""
    _add_case "central-route" failed "Assertion" "Central route not found in ${centralNs} (budget remaining $(_budget_remaining)s)"
    _assert_rc=1
    echo "[readiness] Central route not found in ${centralNs} (budget remaining $(_budget_remaining)s)"
fi

# ---------------------------------------------------------------------------
# Central API TLS verification (fail-closed; must-gather sibling precedent).
# The route is passthrough, so the client sees the generated certificate from
# the central-tls secret (ca.pem) in the Central namespace. Every authenticated
# request below therefore verifies the served certificate against that CA and
# against the name the certificate covers, and the admin password is read only
# after a credential-free handshake has verified: with best_effort: false the
# API answers decide the job, so an unverified server must never receive the
# admin credentials or produce the gate verdict.
# ---------------------------------------------------------------------------
centralApiHost="${centralUrl}"
_apiTlsOpts=""
_CENTRAL_CA_FILE="${ARTIFACT_DIR}/central-api-ca.pem"
_CENTRAL_TLS_ERR="${ARTIFACT_DIR}/central-api-tls.err"

# _central_backend_target <namespace> <service> [<route-target-port>]
# Prints "<address> <port>" for one ready backend of the service, taken from
# the EndpointSlices the endpoint controller maintains for it. When a Route
# target port is given, the port is the one OpenShift resolves for it.
# Exit status: 0 with output for a ready backend; 0 with no output when the
# EndpointSlices were read and list no ready backend; 2 when the read fails;
# 3 when the read returns a body that cannot be parsed. The two error states
# stay distinct from "no ready backend" so a caller cannot record a read
# failure as a definite negative.
_central_backend_target() {
    local _slice_json _backend_target _rt_port="${3:-}"
    _slice_json="$(oc get endpointslices -n "$1" \
      -l "kubernetes.io/service-name=$2" -o json 2>/dev/null)" || return 2
    _backend_target="$(printf '%s\n' "${_slice_json}" | \
      python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(3)

routeTargetPort = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
for item in data.get("items", []):
    ports = [p for p in item.get("ports", []) or [] if p.get("port")]
    if not ports:
        continue
    if routeTargetPort:
        if routeTargetPort.isdigit():
            matched = [p for p in ports if str(p.get("port")) == routeTargetPort]
        else:
            matched = [p for p in ports if str(p.get("name")) == routeTargetPort]
        if not matched:
            # The route selects a port this slice does not expose: a ready
            # endpoint here would redirect --connect-to to the wrong container
            # port, so keep looking at the remaining slices instead of
            # settling for ports[0].
            continue
        ports = matched
    if len(ports) > 1:
        # A single-port service has one entry; prefer an explicitly named https
        # port when several remain.
        ports.sort(key=lambda p: 0 if p.get("name") == "https" else 1)
    for endpoint in item.get("endpoints", []) or []:
        if (endpoint.get("conditions") or {}).get("ready") is False:
            continue
        addresses = endpoint.get("addresses") or []
        if addresses:
            print(addresses[0], ports[0]["port"])
            sys.exit(0)
' "${_rt_port}")" || return 3
    printf '%s\n' "${_backend_target}"
}

_verify_central_api_tls() {
    typeset centralCa="" _route_svc_tp="" _central_svc="" _central_route_tp=""
    typeset _central_backend="" _central_svc_dns="" _central_connect_to=""
    typeset _central_addr="" _central_port=""
    typeset -i _central_backend_rc=0 _central_backend_curl_rc=0

    centralCa="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get secret central-tls -n "${centralNs}" \
        -o jsonpath='{.data.ca\.pem}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -z "${centralCa}" ]]; then
        echo "central-tls ca.pem not readable in ${centralNs}; Central's certificate cannot be verified" >"${_CENTRAL_TLS_ERR}"
        return 1
    fi
    printf '%s\n' "${centralCa}" > "${_CENTRAL_CA_FILE}"

    # Credential-free handshake against the route host, the host the checks
    # below use: curl exit 0 means the served certificate chained to Central's
    # CA (an unauthenticated 401 is still a verified handshake); non-zero means
    # CA or hostname mismatch -- no credential is involved either way.
    if curl -sS -o /dev/null --cacert "${_CENTRAL_CA_FILE}" \
          --connect-timeout 10 --max-time 30 -w '' \
          "https://${centralUrl}/v1/metadata" 2>"${_CENTRAL_TLS_ERR}"; then
        centralApiHost="${centralUrl}"
        _apiTlsOpts="--cacert ${_CENTRAL_CA_FILE}"
        # The handshake redirect above created the error file unconditionally;
        # drop it so a green step publishes no empty central-api-tls.err.
        rm -f "${_CENTRAL_TLS_ERR}"
        echo "[readiness] Central API TLS verified against Central's own CA (route host covered by the certificate)"
        return 0
    fi

    # A passthrough route serving Central's generated certificate can have a
    # route host outside the certificate's service DNS names: the direct
    # handshake then fails hostname verification (curl exit 60) even though the
    # CA is correct. The service DNS name is the name the generated certificate
    # covers, but it cannot be presented as SNI to the route host: a passthrough
    # router picks the backend by TLS SNI route match, so a ClientHello naming
    # the service DNS name selects no route. Retry against a ready backend
    # endpoint of the Central service instead: --connect-to redirects only the
    # TCP connection (backend address and container port) while the URL host
    # stays the service DNS name, so SNI and hostname verification continue to
    # use the verified name against Central's own CA. Routes with a custom
    # certificate that includes the route host pass the direct handshake above
    # and never reach this retry.
    _route_svc_tp="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get route central -n "${centralNs}" \
        -o jsonpath='{.spec.to.name}{"|"}{.spec.port.targetPort}' 2>/dev/null || true)"
    _central_svc="${_route_svc_tp%%|*}"
    if [[ "${_route_svc_tp}" == *'|'* ]]; then
        _central_route_tp="${_route_svc_tp#*|}"
    fi
    if [[ -n "${_central_svc}" ]]; then
        _central_backend="$(
          _central_backend_target "${centralNs}" "${_central_svc}" "${_central_route_tp}"
        )" || _central_backend_rc=$?
    fi
    if [[ "${_central_backend_rc}" -eq 0 && -n "${_central_svc}" && -n "${_central_backend}" ]]; then
        _central_svc_dns="${_central_svc}.${centralNs}.svc"
        read -r _central_addr _central_port <<<"${_central_backend}"
        if [[ "${_central_addr}" == *:* ]]; then
            _central_addr="[${_central_addr}]"
        fi
        _central_connect_to="${_central_svc_dns}:443:${_central_addr}:${_central_port}"
        if curl -sS -o /dev/null --cacert "${_CENTRAL_CA_FILE}" \
              --connect-to "${_central_connect_to}" \
              --connect-timeout 10 --max-time 30 -w '' \
              "https://${_central_svc_dns}/v1/metadata" \
              2>/dev/null; then
            centralApiHost="${_central_svc_dns}"
            _apiTlsOpts="--cacert ${_CENTRAL_CA_FILE} --connect-to ${_central_connect_to}"
            rm -f "${_CENTRAL_TLS_ERR}"
            # Log and artifact text name no service host, backend address or
            # port (INTEROP-9647 log sanitization): curl's own stderr, which
            # carries the service DNS name, is discarded and a failure is
            # recorded as its exit status.
            echo "[readiness] Central API TLS verified against Central's own CA through a ready backend endpoint of the route target service, with the certificate's service name as SNI and verified name (route host outside certificate DNS names)"
            return 0
        else
            _central_backend_curl_rc=$?
            echo "backend-direct TLS handshake against a ready backend endpoint failed (curl exit ${_central_backend_curl_rc})" >>"${_CENTRAL_TLS_ERR}"
        fi
    else
        # Record why the retry could not run: a missing route target, a failed
        # or unparseable EndpointSlice read, and a read that shows no ready
        # backend all leave the retry without a target. Presence only: neither
        # the route target service name nor the backend address belongs in an
        # artifact.
        typeset _svc_present="no" _backend_present="no" _lookup_state=""
        if [[ -n "${_central_svc}" ]]; then
            _svc_present="yes"
        fi
        if [[ -n "${_central_backend}" ]]; then
            _backend_present="yes"
        fi
        if [[ -z "${_central_svc}" ]]; then
            _lookup_state="the route target service is absent, so no EndpointSlice lookup ran"
        elif [[ "${_central_backend_rc}" -eq 2 ]]; then
            _lookup_state="the EndpointSlice read failed, so a ready backend cannot be ruled out"
        elif [[ "${_central_backend_rc}" -eq 3 ]]; then
            _lookup_state="the EndpointSlice read returned an unparseable body, so a ready backend cannot be ruled out"
        else
            _lookup_state="the EndpointSlices read cleanly and list no ready backend"
        fi
        echo "Backend-direct fallback not attempted: route target service present=${_svc_present} ready backend present=${_backend_present} (${_lookup_state})." >>"${_CENTRAL_TLS_ERR}"
    fi
    return 1
}

if [[ -n "${centralUrl}" ]]; then
    if ! _verify_central_api_tls; then
        _add_case "central-api-insecure-tls" failed "TLSVerification" \
            "Central API certificate not verified against the CA in the central-tls secret (route host outside the certificate DNS names and no verifiable ready backend endpoint); no credential is sent to an unverified server"
        echo "[readiness] FATAL: Central API TLS could not be verified; see ${_CENTRAL_TLS_ERR}" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Credential region (D7): set +x bracket spans every credential
# read/check/use/write below -- no set -x may be active at any of these
# sites (static ordering check enforces this).
# ---------------------------------------------------------------------------
set +x

typeset roxAdminPassword=""
echo "[readiness] Extracting roxAdminPassword..."
roxAdminPassword="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get secret -n "${centralNs}" central-htpasswd \
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
# Check: Central API health (authenticated v1/metadata over the TLS connection
# verified above; the assertion case name is retained because the
# verification-channel contract pins the carrier case names)
# ---------------------------------------------------------------------------
function CheckCentralApi () {
    typeset httpCode=""
    # shellcheck disable=SC2086
    httpCode="$(curl -sS ${_apiTlsOpts} -o /dev/null -w '%{http_code}' \
        -K "${_curlCfg}" \
        "https://${centralApiHost}/v1/metadata" --max-time 10)" || return 1
    [[ "${httpCode}" == "200" ]] || return 1
    true
}

if [[ -z "${centralUrl}" ]]; then
    echo "[readiness] Skipping Central API health check due to missing route"
    _add_case "central-api-insecure-tls" skipped "StateAbsent" "central route not found, API check skipped (budget remaining $(_budget_remaining)s)"
else
    if WaitFor "Central API health (v1/metadata)" CheckCentralApi; then
        _add_case "central-api-insecure-tls" passed
    else
        _add_case "central-api-insecure-tls" failed "Assertion" "Central API v1/metadata not healthy (budget remaining $(_budget_remaining)s)"
        _assert_rc=1
    fi
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
    # Body fetch: -f so an HTTP error response fails the pipeline (curl's
    # exit status reaches the `|| return 1`) instead of parsing the error
    # body into a misleading "no connected sensor yet" verdict that burns
    # the whole budget on a credential or routing fault.
    # shellcheck disable=SC2086
    verdict="$(curl -fsSL ${_apiTlsOpts} -K "${_curlCfg}" \
        "https://${centralApiHost}/v1/clusters" --max-time 10 \
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
' )" || return 1
    if [[ "${verdict}" == connected ]]; then
        return 0
    fi
    echo "[readiness]   no connected sensor yet (sensor states: ${verdict#waiting:})"
    return 1
}

if [[ -z "${centralUrl}" ]]; then
    echo "[readiness] Skipping clusters-connected check due to missing route"
    _add_case "clusters-connected" skipped "StateAbsent" "central route not found, clusters check skipped"
else
    if WaitFor "secured cluster connected (v1/clusters)" CheckClustersConnected; then
        _add_case "clusters-connected" passed
    else
        _add_case "clusters-connected" failed "Assertion" "no secured cluster with a connected sensor (v1/clusters) (budget remaining $(_budget_remaining)s)"
        _assert_rc=1
    fi
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
    sensorStatus="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get pods -n "${scNs}" -l app=sensor -o json | python3 -c '
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
' )" || return 1
    if grep -q '^OOMKilled:' <<< "${sensorStatus}"; then
        echo "[readiness] WARNING: OOMKilled detected in sensor containers: $(printf '%s\n' "${sensorStatus}" | sed -n 's/^OOMKilled: //p')"
    fi
    if grep -q '^NO_LIVE_PODS$' <<< "${sensorStatus}"; then
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
    oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get pods -n "${scNs}" -l app=sensor -o wide || true
    oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get pods -n "${scNs}" -l app=sensor -o json | python3 -c '
import json, sys

d = json.load(sys.stdin)
for pod in d.get("items", []):
    meta = pod.get("metadata", {}) or {}
    status = pod.get("status", {}) or {}
    conditions = {c.get("type"): c.get("status") for c in status.get("conditions", []) or []}
    print("%s phase=%s Ready=%s deletionTimestamp=%s" % (
        meta.get("name", "?"), status.get("phase", "?"),
        conditions.get("Ready", "Unknown"), meta.get("deletionTimestamp")))
' || true
    _add_case "sensor-ready" failed "Assertion" "sensor pods not Ready in ${scNs} (budget remaining $(_budget_remaining)s)"
    _assert_rc=1
fi

# ---------------------------------------------------------------------------
# Check: Default policies loaded (count > 80)
# ---------------------------------------------------------------------------
function CheckPoliciesLoaded () {
    typeset policyCount=""
    # Body fetch: -f for the same reason as CheckClustersConnected - an HTTP
    # error response must fail the check, not read as an empty policy list.
    # shellcheck disable=SC2086
    policyCount="$(curl -fsSL ${_apiTlsOpts} -K "${_curlCfg}" \
        "https://${centralApiHost}/v1/policies?query=" --max-time 10 \
        | JsonLength policies)" || return 1
    echo "[readiness]   policy count: ${policyCount}"
    [[ "${policyCount}" -gt 80 ]] || return 1
    true
}

if [[ -z "${centralUrl}" ]]; then
    echo "[readiness] Skipping policies-loaded check due to missing route"
    _add_case "policies-loaded" skipped "StateAbsent" "central route not found, policies check skipped"
else
    if WaitFor "default policies loaded (>80)" CheckPoliciesLoaded; then
        _add_case "policies-loaded" passed
    else
        _add_case "policies-loaded" failed "Assertion" "default policies not loaded (>80 expected; budget remaining $(_budget_remaining)s)"
        _assert_rc=1
    fi
fi

echo "[readiness] Writing connection details to SHARED_DIR..."

echo "${roxAdminPassword}" > "${SHARED_DIR}/ROX_ADMIN_PASSWORD"
if [[ -n "${centralUrl}" ]]; then
    echo "${centralUrl}" > "${SHARED_DIR}/CENTRAL_URL"
else
    echo "[readiness] Skipping CENTRAL_URL write due to missing route (failure marker not published)"
fi
echo "${centralNs}" > "${SHARED_DIR}/CENTRAL_NS"
echo "${scNs}" > "${SHARED_DIR}/SC_NS"

# End of credential region (D7)
set -x

if (( _assert_rc != 0 )); then
    _add_case "stackrox-opp-readiness" failed "Assertion" "readiness assertion failed (budget remaining $(_budget_remaining)s; see individual assertion cases for type and reason)"
    echo "[readiness] One or more readiness assertions failed; see ${_CARRIER}"
    exit 1
fi
_add_case "stackrox-opp-readiness" passed
echo "[readiness] All checks passed. ACS is ready for SMOKE tests."
exit 0
