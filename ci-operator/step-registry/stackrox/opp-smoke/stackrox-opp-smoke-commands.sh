#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit

# --- Trace-to-file: always capture, copy scrubbed on every exit ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# ---------------------------------------------------------------------------
# ACS OPP SMOKE runner (INTEROP-9647 PR-A, team review revision 3 D4/D6/D7)
#
# Contract (fail-closed):
#   INTEROP__OPP__ACS__EXPECTATION   required | absent-by-design   (unset/other => exit 2)
#   Classification runs BEFORE any SHARED_DIR consumption, by this step's
#   own query (the image ships oc): present / absent (0-exit read, 0 items)
#   / unknown (read failure after 3 attempts => FAILED, exit != 0).
#   Carrier junit lp-interop--OPP--stackrox-opp-smoke is emitted on every exit path.
#   A recorded failed case row gates the step, so the exit status always
#   agrees with the carrier: a row recorded as skipped never gates (the
#   scanner-v4-matcher absent path), a row recorded as failed always does
#   (the Environment-typed scanner-v4-ready timeout included).
#   Exit codes: 0 pass / absent-by-design with no failed case row; 1
#   acs-required-but-absent, test failure, or any recorded failed case row;
#   2 invalid input; 3 acs-state-indeterminate.
# ---------------------------------------------------------------------------

if [[ -f "${SHARED_DIR:-}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

INTEROP__OPP__ACS__EXPECTATION="${INTEROP__OPP__ACS__EXPECTATION:-}"
INTEROP__OPP__ACS__SELFTEST="${INTEROP__OPP__ACS__SELFTEST:-true}"

# --- JUnit carrier machinery (deploy-acs precedent, D4/D6) -----------------
_SUITE="lp-interop--OPP--stackrox-opp-smoke"
_CLASSNAME="stackrox-opp-smoke"
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

# Pre-seed a default-failing carrier: a hard SIGKILL before classification
# leaves a failing artifact on disk (never green; D6 / 9525 contract).
_ACS_STATE="unknown"
_add_classification "acs-state-indeterminate" failed "PreSeed" "carrier pre-seed: step exited before classification completed (SIGKILL guard)"
_write_carrier || { echo "[smoke] WARN: carrier pre-seed write failed" >&2; true; }
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

# shellcheck disable=SC2317
_propagate_junit () {
    # Copy the SMOKE suite's own JUnit results to SHARED_DIR/junit for the
    # reporters.  The carrier file is excluded here: its SHARED_DIR copy is
    # governed by the D4 channel split in _write_shared_copy.
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit" || return 1
    typeset _f="" _rc=0 _tmpList="" _find_rc=0
    _tmpList="$(mktemp)" || return 1
    find "${ARTIFACT_DIR}" -maxdepth 1 -name '*.xml' ! -name "junit_${_SUITE}.xml" -print0 > "${_tmpList}" 2>/dev/null || _find_rc=$?
    if (( _find_rc != 0 )); then
        rm -f "${_tmpList}"
        return 1
    fi
    while IFS= read -r -d '' _f; do
        cp "${_f}" "${SHARED_DIR}/junit/" 2>/dev/null || _rc=1
    done < "${_tmpList}"
    rm -f "${_tmpList}"
    return "${_rc}"
}

_save_xtrace() {
    # Scrub credentials before copying, mirror opp-quay-smoke precedent.
    # The copy is gated on the scrub succeeding: an unscrubbed trace can carry
    # credential values, so a failed scrub must leave the log unpublished (the
    # step artifact is what reviewers and the world can read).
    { set +x; } 2>/dev/null
    if ! sed -i -E \
        -e 's/([A-Za-z0-9_]*(password|passwd|token|secret|credential|account|key)[A-Za-z0-9_]*)=[^ ]*/\1=REDACTED/gi' \
        -e 's/Bearer [A-Za-z0-9._~+\/=-]+/Bearer [REDACTED]/g' \
        -e 's|://[^:@/]*:[^:@/]*@|://[REDACTED]:[REDACTED]@|g' \
        "${_xtrace_log}" 2>/dev/null; then
        echo "[smoke] WARN: xtrace scrub failed; not publishing the trace artifact" >&2
        { set -x; } 2>/dev/null
        return 0
    fi
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        cp "${_xtrace_log}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    fi
    { set -x; } 2>/dev/null
}

_jrc=0
trap '_jrc=$?; set +e; { set +x; } 2>/dev/null; _save_xtrace; if (( _jrc != 0 && _N_FAILURES == 0 )); then _add_case "step-exited-nonzero" failed "StepExit" "step exited ${_jrc} without a recorded failure (state=${_ACS_STATE:-unclassified})"; fi; if ! _propagate_junit; then _add_case "junit-propagation" failed "Propagation" "failed to propagate JUnit results to SHARED_DIR"; if (( _jrc == 0 )); then _jrc=1; fi; fi; typeset -i _fin_rc=0; _finalize || _fin_rc=1; if (( _fin_rc != 0 )); then if (( _jrc == 0 )); then _jrc=1; fi; fi; if (( _N_FAILURES > 0 && _jrc == 0 )); then _jrc=1; fi; exit "${_jrc}"' EXIT

# ---------------------------------------------------------------------------
# Self-test (D6 named executor): machinery validation, always on
# ---------------------------------------------------------------------------
_run_selftest() {
    typeset -i st_rc=0
    [[ -w "${ARTIFACT_DIR}" ]] || { echo "[smoke-selftest] FAIL: ARTIFACT_DIR not writable"; st_rc=1; }
    command -v oc >/dev/null 2>&1 || { echo "[smoke-selftest] FAIL: oc not found"; st_rc=1; }
    command -v python3 >/dev/null 2>&1 || { echo "[smoke-selftest] FAIL: python3 not found"; st_rc=1; }
    if (( st_rc == 0 )); then
        _add_case "acs-preflight-selftest" passed
    else
        _add_case "acs-preflight-selftest" failed "SelfTest" "acs-preflight-selftest failed: machinery validation"
    fi
    return "${st_rc}"
}

# ---------------------------------------------------------------------------
# Classification (D4): own query, BEFORE consuming SHARED_DIR
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
        # Every read carries --request-timeout (OC_READ_TIMEOUT, default 10s):
        # a poll loop only re-evaluates its deadline after the call returns, so
        # an unbounded read would overrun the cap it is meant to respect.
        if crdlist="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get crd -o name)"; then
            if ! grep -q '^customresourcedefinition\.apiextensions\.k8s\.io/centrals\.platform\.stackrox\.io$' <<< "${crdlist}"; then
                _ACS_STATE="absent"
                return 0
            fi
            if out="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get centrals.platform.stackrox.io -A -o json)"; then
                items="$(printf '%s' "${out}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))')" || rc=1
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

# --- Fail-closed expectation validation (D4) -------------------------------
case "${INTEROP__OPP__ACS__EXPECTATION}" in
    required|absent-by-design)
        echo "[smoke] INTEROP__OPP__ACS__EXPECTATION=${INTEROP__OPP__ACS__EXPECTATION}"
        ;;
    *)
        _ACS_STATE="unknown"
        _add_classification "acs-expectation-invalid" failed "InvalidInput" \
            "INTEROP__OPP__ACS__EXPECTATION must be 'required' or 'absent-by-design' (got: '${INTEROP__OPP__ACS__EXPECTATION:-unset}'); fail-closed"
        echo "[smoke] FATAL: invalid INTEROP__OPP__ACS__EXPECTATION '${INTEROP__OPP__ACS__EXPECTATION:-unset}'"
        exit 2
        ;;
esac

# --- Fail-closed scanner-seam validation (the readiness pattern): a
# non-positive-integer seam must exit 2 with an InvalidInput carrier
# case, never an arithmetic abort before the carrier exists. Runs
# unconditionally, before the selftest and the connection read.
# Defaults are applied first so an unset seam validates against its
# default, never an empty string.
ACS_SCANNER_WAIT_S="${ACS_SCANNER_WAIT_S:-600}"
ACS_SCANNER_POLL_S="${ACS_SCANNER_POLL_S:-30}"
for _seam in ACS_SCANNER_WAIT_S ACS_SCANNER_POLL_S; do
    if ! [[ "${!_seam}" =~ ^[1-9][0-9]*$ ]]; then
        _add_classification "acs-env-invalid" failed "InvalidInput" \
            "${_seam} must be a positive integer (got: '${!_seam}'); fail-closed"
        echo "[smoke] FATAL: invalid ${_seam}='${!_seam}'"
        exit 2
    fi
done

if [[ "${INTEROP__OPP__ACS__SELFTEST}" != "false" ]]; then
    if ! _run_selftest; then
        exit 2
    fi
fi

_classify
echo "[smoke] ACS state classified: ${_ACS_STATE}"

if [[ "${_ACS_STATE}" == "unknown" ]]; then
    _add_classification "acs-state-indeterminate" failed "Classification" \
        "acs-unclassified:central-query/read failed after 3 attempts; never classified as absent without a successful read"
    exit 3
fi

if [[ "${_ACS_STATE}" == "absent" ]]; then
    if [[ "${INTEROP__OPP__ACS__EXPECTATION}" == "required" ]]; then
        _add_classification "acs-required-but-absent" failed "Classification" \
            "acs-central-not-created: Central CR absent on a successful read while INTEROP__OPP__ACS__EXPECTATION=required"
        _add_case "stackrox-opp-smoke" failed "Classification" "Central CR absent on a successful read while INTEROP__OPP__ACS__EXPECTATION=required (no discovery wait)"
        echo "[smoke] Central CR absent but required by INTEROP__OPP__ACS__EXPECTATION"
        exit 1
    fi
    _add_classification "acs-absent-by-design" passed
    echo "[smoke] Central CR absent by design (INTEROP__OPP__ACS__EXPECTATION=absent-by-design); nothing to smoke-test"
    exit 0
fi

_add_classification "acs-present" passed

# Terminal-state wait for SecuredCluster CR: oc wait --for=create with --all never waits on kubectl v1.31 (empty list visits nothing). Use a bounded poll loop with wall-clock deadline instead.
_smokeCheckScExists() {
    typeset _out="" _cnt=""
    _out="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get securedclusters.platform.stackrox.io --all-namespaces -o json)" || return 1
    _cnt="$(printf '%s' "${_out}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))')" || return 1
    (( _cnt > 0 ))
}
typeset -i _smokeTermCap=900
typeset -i _smokeDeadline=$(( $(date +%s) + _smokeTermCap ))
typeset -i _smokeFound=0
typeset -i _smokeFailedLooks=0
typeset -i _smokeAppearedLate=0
while true; do
    if _smokeCheckScExists; then
        _smokeFound=1
        # A first-look success means the workload existed when this step
        # started; any later success means it appeared during this wait, after
        # readiness had already run and published (or not) its handoff.
        if (( _smokeFailedLooks > 0 )); then
            _smokeAppearedLate=1
        fi
        break
    fi
    _smokeFailedLooks=$((_smokeFailedLooks + 1))
    typeset -i _smokeNow
    _smokeNow=$(date +%s)
    if (( _smokeNow >= _smokeDeadline )); then
        break
    fi
    typeset -i _smokeRemain _smokeSleep
    _smokeRemain=$(( _smokeDeadline - _smokeNow ))
    _smokeSleep=30
    (( _smokeRemain < _smokeSleep )) && _smokeSleep=_smokeRemain
    sleep "${_smokeSleep}"
done
typeset -i _termWaitTimedOut=0
if (( _smokeFound == 0 )); then
    _termWaitTimedOut=1
    echo "[smoke] SecuredCluster terminal wait: no SecuredCluster CR created within 900s" >&2
fi

# No SecuredCluster workload in lane: the terminal wait above records a failed
# securedcluster-discovery case when the CR never appears, and this branch fails
# the step rather than skipping (a skipped row never gates a lane, so a required
# lane must not exit 0 here). Check before reading SHARED_DIR so a readiness skip
# does not cause a missing-file exit without a recorded failure.
# Capture first, then test for emptiness: `-o name` prints the lowercase
# singular kind (`securedcluster.platform.stackrox.io/<name>`), so matching
# the plural spelling skips every lane; the capture also keeps grep's SIGPIPE
# out of the pipeline under pipefail and separates a failed read (recorded
# failed row, fail-closed) from a 0-exit read that lists nothing (skip row).
typeset _scList=""
typeset -i _sc_rc=0 _sc_attempt=0
for _sc_attempt in 1 2 3; do
    if _scList="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get securedclusters.platform.stackrox.io --all-namespaces -o name)"; then
        _sc_rc=0
        break
    else
        _sc_rc=$?
        if (( _sc_attempt < 3 )); then
            sleep $(( _sc_attempt * 2 ))
        fi
    fi
done
if (( _sc_rc != 0 )); then
    _add_case "stackrox-opp-smoke" failed "Assertion" "SecuredCluster read failed after the terminal wait; absence not established"
    exit 1
fi
if [[ -z "${_scList}" ]]; then
    _add_case "scanner-v4-ready" skipped "NoSecuredCluster" "no SecuredCluster in lane: scanner not evaluated"
    if [[ "${INTEROP__OPP__ACS__EXPECTATION}" == "required" ]]; then
        if (( _termWaitTimedOut )); then
            _add_case "securedcluster-discovery" failed "Timeout" "SecuredCluster discovery timeout after 900s: no SecuredCluster CR created within 900s"
        else
            _add_case "securedcluster-discovery" failed "Discovery" "SecuredCluster list empty after the terminal wait (recorded failures ${_N_FAILURES}); workload is absent while INTEROP__OPP__ACS__EXPECTATION=required"
        fi
        _add_case "stackrox-opp-smoke" failed "Discovery" "SecuredCluster discovery failed (recorded failures ${_N_FAILURES}); workload is absent while INTEROP__OPP__ACS__EXPECTATION=required"
        exit 1
    fi
    if (( _termWaitTimedOut )); then
        _add_case "securedcluster-discovery" skipped "NoSecuredCluster" "no SecuredCluster CR created within 900s and INTEROP__OPP__ACS__EXPECTATION=${INTEROP__OPP__ACS__EXPECTATION}: not required in this lane"
    fi
    _add_case "stackrox-opp-smoke" skipped "NoSecuredCluster" "no SecuredCluster in lane: smoke not evaluated (INTEROP__OPP__ACS__EXPECTATION=${INTEROP__OPP__ACS__EXPECTATION})"
    exit 0
fi
# ---------------------------------------------------------------------------
# Present: run the SMOKE suite (existing flow)
# ---------------------------------------------------------------------------
echo "[smoke] Reading connection details from SHARED_DIR..."
# Readiness publishes the handoff (ROX_ADMIN_PASSWORD, CENTRAL_URL, CENTRAL_NS)
# only on its state=present path that reaches the writes. Two reachable states
# leave this step without one: readiness skipped because no SecuredCluster
# existed yet (the CR then appears inside smoke's own terminal wait), and a
# present Central whose route was absent (readiness skips the CENTRAL_URL
# write). Name the gap instead of dying inside a `cat` under errexit, which
# surfaces only as an unattributed non-zero exit.
typeset -a _missingHandoff=()
typeset _hf=""
for _hf in CENTRAL_URL ROX_ADMIN_PASSWORD CENTRAL_NS; do
    [[ -s "${SHARED_DIR}/${_hf}" ]] || _missingHandoff+=("${_hf}")
done
if (( ${#_missingHandoff[@]} > 0 )); then
    # Name the cause instead of the two possibilities: a late-appearing
    # SecuredCluster and a readiness run that saw a present Central without a
    # route are different lane faults, and the handoff cannot be recovered
    # here either way (readiness is not re-runnable), so this stays fail-closed
    # in every EXPECTATION mode.
    typeset _handoffCause=""
    if (( _smokeAppearedLate )); then
        _handoffCause="the SecuredCluster appeared during this step's own terminal wait, after readiness had already classified the lane (late appearance, INTEROP__OPP__ACS__EXPECTATION=${INTEROP__OPP__ACS__EXPECTATION}); readiness is not re-runnable, so no handoff exists"
    elif [[ ${#_missingHandoff[@]} -eq 1 && "${_missingHandoff[0]}" == "CENTRAL_URL" ]]; then
        _handoffCause="readiness found a present Central whose route was absent, so it published the credential and namespaces but skipped CENTRAL_URL"
    else
        _handoffCause="readiness stopped before publishing the handoff (no state=present path reached the writes)"
    fi
    _add_case "stackrox-opp-smoke" failed "Handoff" \
        "readiness published no usable connection handoff in SHARED_DIR (missing: ${_missingHandoff[*]}); ${_handoffCause}"
    echo "[smoke] FATAL: readiness published no usable connection handoff (missing: ${_missingHandoff[*]}); ${_handoffCause}" >&2
    exit 1
fi
set +x
typeset centralUrl=''
centralUrl="$(cat "${SHARED_DIR}/CENTRAL_URL")"
ROX_ADMIN_PASSWORD="$(cat "${SHARED_DIR}/ROX_ADMIN_PASSWORD")"
set -x
echo "[smoke] Connection details loaded from SHARED_DIR"

# ---------------------------------------------------------------------------
# Scanner V4 readiness gate: the scan-dependent policy tests (Fixable CVSS
# >= 7 among them) read vulnerability results produced by the Scanner V4
# matcher pods. When those pods are down (observed: matcher pods evicted in
# a storage-pressure window, none running for ~3h; rehearsal build
# 2118028576879022080), the tests fail with MISSING_SCAN_DATA, which looks
# like a policy regression but is an environment condition. Give the
# matcher a bounded head start and record a named case either way, so the
# failure attribution is explicit instead of implicit in the suite output.
# ---------------------------------------------------------------------------
_centralNs="$(cat "${SHARED_DIR}/CENTRAL_NS" 2>/dev/null || true)"
if [[ -z "${_centralNs}" ]]; then
    # The handoff guard above already requires CENTRAL_NS, so this fallback is
    # unreachable in normal flow and stays as belt-and-braces; it is logged so a
    # future regression cannot look like a healthy default namespace.
    echo "[smoke] WARN: SHARED_DIR/CENTRAL_NS is empty; falling back to 'stackrox' for the scanner gate" >&2
    _centralNs="stackrox"
fi
# Capture first, then match: grep -q closes the pipe as soon as it matches, and
# under pipefail that SIGPIPE fails the read (same cure as the sensor-state
# greps later in this step). The capture keeps the read's status out of the
# pipe, so the three outcomes stay distinct: a failed deployment read records
# a failed case row, which increments the failure count so the exit block
# below gates the step (a skip row would let a transient API error exit 0); a
# 0-exit read that lists no matcher deployment records the skip row; and a
# 0-exit read that lists the matcher enters the bounded wait loop.
typeset _deps=""
typeset -i _deps_rc=0 _deps_attempt=0
for _deps_attempt in 1 2 3; do
    if _deps="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get deployment -n "${_centralNs}" -o name)"; then
        _deps_rc=0
        break
    else
        _deps_rc=$?
        if (( _deps_attempt < 3 )); then
            sleep $(( _deps_attempt * 2 ))
        fi
    fi
done
if (( _deps_rc != 0 )); then
    echo "[smoke] Deployment read failed in ${_centralNs} (status ${_deps_rc}); scanner readiness gate not evaluated"
    _add_case "scanner-v4-ready" failed "Environment" "deployment read failed in ${_centralNs} (oc get deployment status ${_deps_rc}); the scanner readiness gate was not evaluated"
elif ! grep -qx 'deployment.apps/scanner-v4-matcher' <<< "${_deps}"; then
    echo "[smoke] Scanner V4 matcher not deployed in ${_centralNs}; skipping scanner readiness gate"
    _add_case "scanner-v4-ready" skipped "ScannerGate" "no scanner-v4-matcher deployment in ${_centralNs}; scan-dependent results follow suite behavior"
else
    echo "[smoke] Waiting for a Ready scanner-v4-matcher pod (cap ${ACS_SCANNER_WAIT_S}s)..."
    typeset -i _scan_deadline=$(( $(date +%s) + ACS_SCANNER_WAIT_S ))
    typeset _scan_ready=""
    while true; do
        _scan_ready="$(oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get pods -n "${_centralNs}" -l app=scanner-v4-matcher -o json | python3 -c '
import json, sys

d = json.load(sys.stdin)
for pod in d.get("items", []):
    meta = pod.get("metadata", {}) or {}
    status = pod.get("status", {}) or {}
    if status.get("phase") in ("Succeeded", "Failed") or meta.get("deletionTimestamp") is not None:
        continue
    conditions = {c.get("type"): c.get("status") for c in status.get("conditions", []) or []}
    if conditions.get("Ready") == "True":
        print(meta.get("name", "?"))
        break
' || true)"
        if [[ -n "${_scan_ready}" ]]; then
            break
        fi
        typeset -i _scan_now
        _scan_now=$(date +%s)
        if (( _scan_now >= _scan_deadline )); then
            break
        fi
        typeset -i _scan_remain _scan_sleepFor
        _scan_remain=$(( _scan_deadline - _scan_now ))
        _scan_sleepFor=$(( _scan_remain < ACS_SCANNER_POLL_S ? _scan_remain : ACS_SCANNER_POLL_S ))
        sleep "${_scan_sleepFor}"
    done
    if [[ -n "${_scan_ready}" ]]; then
        echo "[smoke] Scanner V4 matcher ready: ${_scan_ready}"
        _add_case "scanner-v4-ready" passed
    else
        echo "[smoke] Scanner V4 matcher pods not Ready within ${ACS_SCANNER_WAIT_S}s:"
        oc --request-timeout="${OC_READ_TIMEOUT:-10s}" get pods -n "${_centralNs}" -l app=scanner-v4-matcher -o wide || true
        _add_case "scanner-v4-ready" failed "Environment" "no Ready scanner-v4-matcher pod in ${_centralNs} within ${ACS_SCANNER_WAIT_S}s; scan-dependent test results may report MISSING_SCAN_DATA for environment reasons"
    fi
fi

STACKROX_REF="${STACKROX_REF:-master}"
SCANNER_REF="${SCANNER_REF:-master}"

echo "[smoke] Sparse-cloning stackrox/stackrox..."
cd /tmp
rm -rf stackrox scanner
git clone --depth 1 --filter=blob:none --sparse --branch "${STACKROX_REF}" \
    https://github.com/stackrox/stackrox.git stackrox
cd stackrox
git sparse-checkout set qa-tests-backend/ proto/

echo "[smoke] Fetching scanner protos..."
git clone --depth 1 --filter=blob:none --sparse --branch "${SCANNER_REF}" \
    https://github.com/stackrox/scanner.git /tmp/scanner
cd /tmp/scanner
git sparse-checkout set proto/scanner
cp -r proto/scanner /tmp/stackrox/qa-tests-backend/src/main/proto/scanner
chmod -R u+w /tmp/stackrox/qa-tests-backend/src/main/proto/scanner

echo "[smoke] Materializing proto sources (replace symlinks with copies)..."
cd /tmp/stackrox/qa-tests-backend/src/main/proto
typeset target=''
for link in api internalapi storage test tools; do
    if [[ -L "${link}" ]]; then
        target="$(readlink -f "${link}")"
        rm "${link}"
        cp -r "${target}" "${link}"
    fi
done

echo "[smoke] Patching DEFAULT_CLUSTER_NAME to 'local-cluster'..."
sed -i 's/DEFAULT_CLUSTER_NAME = "remote"/DEFAULT_CLUSTER_NAME = "local-cluster"/' \
    /tmp/stackrox/qa-tests-backend/src/main/groovy/services/ClusterService.groovy
grep -q 'DEFAULT_CLUSTER_NAME = "local-cluster"' \
    /tmp/stackrox/qa-tests-backend/src/main/groovy/services/ClusterService.groovy \
    || { echo "[smoke] FATAL: DEFAULT_CLUSTER_NAME patch failed"; exit 1; }

export API_HOSTNAME="${centralUrl}"
export API_PORT="443"
export ROX_USERNAME="admin"
set +x
export ROX_ADMIN_PASSWORD
REGISTRY_USERNAME="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/QUAY_RHACS_ENG_RO_USERNAME)"
export REGISTRY_USERNAME
REGISTRY_PASSWORD="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/QUAY_RHACS_ENG_RO_PASSWORD)"
export REGISTRY_PASSWORD
if [[ -f /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_CREDENTIALS_GCR_SCANNER_V2 ]]; then
    GOOGLE_CREDENTIALS_GCR_SCANNER_V2="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_CREDENTIALS_GCR_SCANNER_V2)"
    export GOOGLE_CREDENTIALS_GCR_SCANNER_V2
fi
if [[ -f /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2 ]]; then
    GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2)"
    export GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2
fi
set -x
export CLUSTER="OPENSHIFT"
export CI="true"
export POD_SECURITY_POLICIES="false"
export TEST_TARGET="smoke-test"

cd /tmp/stackrox/qa-tests-backend

cat > /tmp/fix-proto-deps.gradle <<'INIT'
allprojects {
    afterEvaluate {
        tasks.matching { it.name == 'compileGroovy' }.configureEach {
            dependsOn tasks.matching { it.name == 'generateProto' }
        }
    }
}
INIT

echo "[smoke] Running testSMOKE..."
typeset -i testExit=0
./gradlew testSMOKE --no-daemon --init-script /tmp/fix-proto-deps.gradle \
    -Dorg.gradle.jvmargs="-Xmx2g" || testExit=$?

echo "[smoke] Copying JUnit results to ARTIFACT_DIR..."
if [[ -d build/test-results/testSMOKE ]]; then
    find build/test-results/testSMOKE -name '*.xml' -exec cp -v {} "${ARTIFACT_DIR}/" \;
fi

if [[ -d build/reports/tests/testSMOKE ]]; then
    mkdir -p "${ARTIFACT_DIR}/smoke-report"
    find build/reports/tests/testSMOKE -mindepth 1 -maxdepth 1 \
        -exec cp -r {} "${ARTIFACT_DIR}/smoke-report/" \;
fi

echo "[smoke] Test run finished with exit code: ${testExit}"
if (( testExit != 0 )); then
    _add_case "stackrox-opp-smoke" failed "TestFailure" "smoke test failure (Gradle exit ${testExit}, recorded failures ${_N_FAILURES})"
    exit 1
elif (( _N_FAILURES > 0 )); then
    _add_case "stackrox-opp-smoke" failed "Environment" "environment failure without test failure (Gradle exit ${testExit}, recorded failures ${_N_FAILURES})"
    exit 1
fi
_add_case "stackrox-opp-smoke" passed
exit 0
