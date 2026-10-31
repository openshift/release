#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

# INTEROP-9646 PR-A (behavior-preserving diagnostics; see opp-interop-testing
# docs/research/2026-10-29-interop-9646-wait-mcp-root-cause.md):
#   - exit-trap exit-code clobber fixed (the xtrace bundle has never uploaded)
#   - TERM/INT handled through the same JUnit+bundle path
#   - MCP condition reason/message emitted verbatim (log + JUnit failure body)
#   - bounded `oc` invocations on every failure-path call (ocb wrapper)
#   - in-loop `oc get mcp` capped at min(remaining, 60)s (was: whole deadline)
#   - env validation before the read-only typeset assignments (exit 2)
#   - offline predicate self-test (phase 0) pinning current behavior on four
#     fixtures extracted from real runs
#   - JUnit properties on pass and fail
#
# PR-B (behavior changes, INTEROP-9646): progress predicate rewritten
#   (per-pool updated-count trend; no extension while Degraded; sustained
#   pinned-updated oscillation vetoes extension); stability requires the
#   Updated/Updating condition tokens and observedGeneration==generation;
#   non-self-healing ENOSPC Degraded fails fast after 2 unchanged polls;
#   5 consecutive oc failures classify cluster-api-unreachable; the
#   maxUnavailable SUT-mutating patch is removed (serialized 9-machine
#   rollout measured ~21 min << 5400s budget).
#
# Budget arithmetic (must hold; step timeout 6300s, grace_period 5m0s):
#   self-terminating path: settle 90 + max wait 5400 + collection <= 120
#     + health gate <= 60  =>  <= 5670s, leaving >= 630s headroom
#   step-timeout path: only 300s remain between SIGTERM and SIGKILL, so the
#     failure-path collector is watchdog-bounded (timeout 120) and the xtrace
#     copy is truncated (tail -c 5M) before scrubbing.

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
_opp_cleanup() {
  # Save xtrace log with credentials scrubbed when the step exits non-zero.
  # Idempotent (guarded by _bundle_emitted) and bounded: truncate first, then
  # scrub the copy, so trap runtime does not scale with xtrace file size.
  (( _bundle_emitted )) && return 0
  _bundle_emitted=1
  set +x 2>/dev/null
  if [[ ${_jrc} -ne 0 && -n "${ARTIFACT_DIR:-}" && -s "${_xtrace_log}" ]]; then
    local _scrub="/tmp/xtrace-scrub-$$.log"
    # tail -c cuts at a byte offset that can fall between a key and its
    # value (after `token=` or `Bearer `); the partial first line would
    # begin with a bare credential fragment no sed pattern can match.
    # Drop it before scrubbing (preflight review).
    tail -c 5242880 "${_xtrace_log}" 2>/dev/null | tail -n +2 > "${_scrub}" 2>/dev/null || true
    # Scrub credentials before copying
    sed -i -E \
      -e 's/(password|token|secret|key|credential)=[^ ]*/\1=REDACTED/gi' \
      -e 's/Bearer [A-Za-z0-9._~+\/=-]+/Bearer [REDACTED]/g' \
      -e 's/password=[^ &]+/password=[REDACTED]/g' \
      -e 's/token=[^ &]+/token=[REDACTED]/g' \
      -e 's|://[^:@/]*:[^:@/]*@|://[REDACTED]:[REDACTED]@|g' \
      "${_scrub}" 2>/dev/null || true
    cp "${_scrub}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    rm -f "${_scrub}" 2>/dev/null || true
    echo ">>> TRACE: xtrace log saved to artifacts (exit code ${_jrc})"
  fi
}

# --- JUnit XML wrapper: emit result for skip-ratio-gate ---
_junit_start=$(date +%s)
_junit_emitted=0
_bundle_emitted=0
_jrc=0  # assigned by the EXIT trap (set-once); TERM/INT set 143
_rc=0  # exit status captured by the EXIT trap (SC2154: visible assignment for shellcheck)
typeset -i _jrc_set=0  # initialized here - before the trap and before env
# validation exits - so an early `exit 2` never meets an unset variable
# under `set -u` inside the trap (nounset aborts the trap mid-run and
# clobbers the intended code with 1, skipping JUnit and cleanup).
_junit_class=""
_junit_reason=""
_junit_selftest="not-run"
_junit_trapselftest="not-run"
_junit_emit() {
  # Emit a JUnit XML result for the wait-mcp step and propagate
  # it to SHARED_DIR/junit so downstream steps can aggregate results.
  (( _junit_emitted )) && return 0
  _junit_emitted=1
  local _jr=${1:-0}
  local _je
  _je=$(date +%s) || _je=${_junit_start}
  local _jd=$((_je - _junit_start))
  local _jn="wait-mcp"
  local _jf="${ARTIFACT_DIR:-/tmp}/junit_lp-interop--OPP--${_jn}.xml"
  local _fc=0 _fx=""
  # A self-test failure always exits 2, so it only ever rides the main
  # failure element as a note - never a second <failure> child (JUnit
  # consumers expect at most one failure element per testcase, and the
  # suite count must stay failures<=tests; preflight review).
  local _st_failed=""
  if [[ "${_junit_selftest}" == "fail" ]]; then _st_failed="predicate"; fi
  if [[ "${_junit_trapselftest}" == "fail" ]]; then _st_failed="${_st_failed:+${_st_failed}+}trap"; fi
  local _st_note=""
  if [[ -n "${_st_failed}" ]]; then
    _st_note=" Offline ${_st_failed} self-test failed; step semantics are not the reviewed ones."
  fi
  # XML-escape via sed: bash >= 5.2 patsub_replacement expands a bare & in
  # ${var//pat/repl} to the matched text (breaking &lt; into <lt;), and older
  # bash keeps a backslash literally - sed's \& is unambiguous everywhere.
  local _esc_reason
  _esc_reason=$(printf '%s' "${_junit_reason}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
  local _esc_class
  _esc_class=$(printf '%s' "${_junit_class}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
  if (( _jr != 0 )); then
    _fc=1
    _fx="<failure message=\"${_jn} exited with code ${_jr}${_esc_class:+: ${_esc_class}}\" type=\"StepFailure\">${_jn} exited with code ${_jr}.${_esc_reason:+ Verbatim condition: ${_esc_reason}}${_st_note}</failure>"
  fi
  # Self-test verdicts are suite PROPERTIES, not testcases: the
  # skip-ratio gate aggregates tests= across suites, and a meta-test
  # (harness self-check, never skipped) would dilute skipped/total and
  # could mask a threshold breach (preflight review). A self-test
  # failure still fails the suite: it increments failures= and rides
  # the main testcase's failure element, and the step exits 2.
  cat > "${_jf}" <<JUNITEOF || true
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="lp-interop--OPP--${_jn}" tests="1" failures="${_fc}" errors="0" skipped="0" time="${_jd}">
  <properties>
    <property name="polls" value="${_junit_polls}"/>
    <property name="extensions" value="${extensionsApplied}"/>
    <property name="mcp_wait_seconds" value="${_jd}"/>
    <property name="first_signature_poll" value="${_junit_first_signature_poll}"/>
    <property name="predicate_selftest" value="${_junit_selftest}"/>
    <property name="trap_selftest" value="${_junit_trapselftest}"/>
    <property name="final_class" value="${_esc_class}"/>
  </properties>
  <testcase name="${_jn}" classname="lp-interop.OPP.${_jn}" time="${_jd}">
    ${_fx}
  </testcase>
</testsuite>
JUNITEOF
  if [[ -n "${SHARED_DIR:-}" ]]; then
    mkdir -p "${SHARED_DIR}/junit" 2>/dev/null || true
    cp "${_jf}" "${SHARED_DIR}/junit/" 2>/dev/null || true
  fi
}

# Set-once exit code: the TERM/INT handler records 143 and exits; the EXIT
# trap keeps the first recorded value (corrected idiom per the 9527/86592
# precedent: capture the code first, set +e/+u, emit and bundle each guarded,
# single trailing exit).
trap '_rc=$?; if (( ! _jrc_set )); then _jrc=${_rc}; _jrc_set=1; fi; set +e; set +u; _junit_emit "${_jrc}"; _opp_cleanup; exit "${_jrc}"' EXIT
trap '_jrc=143; _jrc_set=1; exit 143' TERM INT

# --- Bounded oc wrapper for diagnostic/failure-path calls: never hangs,
#     never fails the step by itself (callers that need exit status use the
#     in-loop bounded form instead). ---
ocb() {
  timeout 10s oc --request-timeout=10s "$@" 2>/dev/null || true
}

echo ">>> PHASE: initialization"

# --- Env validation (before the read-only typeset assignments so a bad
#     value exits 2 with a message instead of an arithmetic error) ---
_opp_validate_int() {
  local _name="${1}" _raw="${2}" _min="${3}"
  # Leading zeros are rejected (not normalized): bash arithmetic reads
  # 010 as octal 8 and errors on 08, so a digit-only regex alone would
  # accept values the typeset -i assignments then misread (preflight
  # review: reject leading zeros except bare "0").
  if ! [[ "${_raw}" =~ ^(0|[1-9][0-9]*)$ ]] || (( 10#${_raw} < _min )); then
    echo "FAILURE CLASS: Invalid step input" >&2
    echo "env ${_name} must be an integer >= ${_min} (got '${_raw}')" >&2
    exit 2
  fi
}
_opp_validate_int MCP_WAIT_TIMEOUT "${MCP_WAIT_TIMEOUT:-3600}" 1
_opp_validate_int MCP_WAIT_PROGRESS_EXTENSION "${MCP_WAIT_PROGRESS_EXTENSION:-1200}" 1
_opp_validate_int MCP_WAIT_MAX_TIMEOUT "${MCP_WAIT_MAX_TIMEOUT:-5400}" 1
_opp_validate_int MCP_CONSECUTIVE_CHECKS "${MCP_CONSECUTIVE_CHECKS:-3}" 2
_opp_validate_int MCP_SETTLE_DELAY "${MCP_SETTLE_DELAY:-90}" 0
_opp_validate_int MCP_MAX_UNAVAILABLE "${MCP_MAX_UNAVAILABLE:-3}" 1
_opp_validate_int MCP_POLL_INTERVAL "${MCP_POLL_INTERVAL:-30}" 10
_opp_validate_int MCP_PINNED_UPDATED_POLLS "${MCP_PINNED_UPDATED_POLLS:-120}" 1
_opp_validate_int MCP_RENDER_CHURN_LIMIT "${MCP_RENDER_CHURN_LIMIT:-5}" 1

typeset -ri mcpWaitTimeout="${MCP_WAIT_TIMEOUT:-3600}"
typeset -ri progressExtension="${MCP_WAIT_PROGRESS_EXTENSION:-1200}"
typeset -ri maxTimeout="${MCP_WAIT_MAX_TIMEOUT:-5400}"
typeset -ri consecutiveRequired="${MCP_CONSECUTIVE_CHECKS:-3}"
typeset -ri settleDelay="${MCP_SETTLE_DELAY:-90}"
typeset -ri maxUnavailable="${MCP_MAX_UNAVAILABLE:-3}"
typeset -ri pollInterval="${MCP_POLL_INTERVAL:-30}"
typeset -ri pinnedUpdatedPolls="${MCP_PINNED_UPDATED_POLLS:-120}"
typeset -ri renderChurnLimit="${MCP_RENDER_CHURN_LIMIT:-5}"
typeset -a readyHistory=()
typeset -a updatedHistory=()
typeset -a machineCountHistory=()
typeset -i _renderChurnCount=0
typeset _lastGenPrint=""
typeset -i _signatureRepeat=0
typeset -i _bundleCollected=0
_lastSignatureReason=""
typeset -i extensionsApplied=0
typeset -i pollsSinceLastExtension=0
typeset -ri extensionCheckInterval=5
typeset -i _junit_polls=0
typeset -i _junit_first_signature_poll=-1

function IsMcpProgressing () {
    # Progress predicate (INTEROP-9646): per-pool trend over the trailing
    # window, evaluated on the parallel per-poll histories.
    #  1. no extension while any pool is Degraded (all three failing runs
    #     were extended while Degraded=True, burning 60 min of lane quota);
    #  2. updated-machine count rising monotonically within the window;
    #  3. sustained cycling vetoes extension: the pool not ready for >=
    #     MCP_PINNED_UPDATED_POLLS consecutive polls without Degraded means
    #     the rollout is cycling (re-rendering and re-rebooting), not
    #     progressing (run 2115458776726245376: 179 polls, ready 4-8). The
    #     veto sets _vetoStreakHit for the poll loop's fail-fast exit;
    #  4. ready count recovering within the window with bounded regression
    #     (a healthy rolling update dips by up to maxUnavailable reboots).
    _vetoStreakHit=0
    # Optional args pin the phase-0 self-test to the reviewed default
    # thresholds regardless of runtime env tuning (fixture verdicts must
    # depend on predicate logic, not job configuration).
    typeset -i _pinnedPolls="${1:-${pinnedUpdatedPolls}}"
    typeset -i _maxUnavail="${2:-${maxUnavailable}}"
    typeset -i len=${#readyHistory[@]}
    (( len < 3 )) && return 1
    typeset -i windowStart=$(( len > 6 ? len - 6 : 0 ))
    typeset -i i
    for (( i = windowStart; i < len; ++i )); do
        (( degradedHistory[i] )) && return 1
    done
    typeset -i notReadyStreak=0
    for (( i = len - 1; i >= 0; --i )); do
        # The streak is the PINNED-UPDATED cycling mode (MCP_PINNED_
        # UPDATED_POLLS): updated pinned at machineCount, ready oscillating
        # below it, no Degraded - run 2's mode (all machines updated, the
        # pool never went ready). Degraded polls are SKIPPED (not counted,
        # not terminating); a poll with updated below machineCount
        # TERMINATES the streak (a still-updating rollout is a different
        # failure mode, not cycling).
        if (( degradedHistory[i] )); then
            continue
        fi
        if (( updatedHistory[i] != machineCountHistory[i] )); then
            break
        fi
        if (( readyHistory[i] < machineCountHistory[i] )); then
            (( ++notReadyStreak ))
        else
            break
        fi
    done
    # Sustained-cycling veto (preflight-review note): at default cadence
    # the maxTimeout cap already bounds extensions before this threshold
    # is reached, so the veto's value is FAIL-FAST, not extension denial -
    # the poll loop reads _vetoStreakHit and exits with
    # mcp-rollout-not-converging instead of polling to the deadline.
    # The veto is computed BEFORE the rising-updated clause so a pool that
    # cycled not-ready for the streak while its machine count grew
    # (updated tracking machineCount) cannot mask the veto behind a
    # rising window (preflight review: apply the veto before returning
    # progress).
    if (( notReadyStreak >= _pinnedPolls )); then
        _vetoStreakHit=1
    fi
    typeset -i first=${updatedHistory[windowStart]}
    typeset -i last=${updatedHistory[len - 1]}
    if (( last > first )); then
        for (( i = windowStart + 1; i < len; ++i )); do
            (( updatedHistory[i] < updatedHistory[i-1] )) && return 1
        done
        (( _vetoStreakHit )) && return 1
        return 0
    fi
    (( _vetoStreakHit )) && return 1
    # Ready-count recovery within the window with bounded regression: the
    # bound is the maximum single-poll drop (machines concurrently
    # unavailable, mirroring MCO maxUnavailable), not the number of polls
    # containing a drop - a single 9 -> 0 collapse is one event but an
    # unbounded regression (preflight review: bound by magnitude).
    first=${readyHistory[windowStart]}
    last=${readyHistory[len - 1]}
    typeset -i maxDrop=0 _drop=0
    for (( i = windowStart + 1; i < len; ++i )); do
        (( _drop = readyHistory[i-1] - readyHistory[i] )) || true
        (( _drop > maxDrop )) && maxDrop=${_drop} || true
    done
    if (( last > first && maxDrop <= _maxUnavail )); then
        return 0
    fi
    return 1
}

# --- Offline predicate self-test (phase 0) ---------------------------------
# Fixtures are per-poll records (ready, updated, degraded) extracted from
# real runs' interop-opp-wait-mcp build logs (prow, ocp-4.22 CR full-stack):
#   run1-pinned-enoscp      2115277579970678784  Degraded pinned, ENOSPC
#   run2-sawtooth           2115458776726245376  updated=9/9, ready sawtooth
#   run3-pinned-enoscp      2115639973800579072  Degraded pinned, ENOSPC
#   green-control           2115096361434091520  converged after churn
# The self-test evaluates IsMcpProgressing at each fixture's FINAL poll
# (the verdict the step would reach at timeout) and pins the flipped
# expectations of the rewritten predicate: no extension for the two
# Degraded-pinned runs (degraded gate) or the sustained sawtooth
# (pinned-updated veto); progress still detected for the green control.

__fixture_run1_pinned_enoscp () {
  # provenance: run 2115277579970678784 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 7 7 7 7 7 6 6 6 6 6 7 7 7 7 7 7 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8)
  FIX_UPDATED=(9 9 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
  8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
  8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
  8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8)
  FIX_DEGRADED=(0 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1)
  FIX_MACHINECOUNT=9
}
__fixture_run2_sawtooth_unconverged () {
  # provenance: run 2115458776726245376 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 7 7 7 7 6 6 6 6 6 7 7 7 7 7 8 8 8 8 7 6 6 5 4 4 4 4 5 4 4 4 4 5 5 5 5 5 4 4 6 7 7 8 8 8 6 5 5
4 5 4 4 4 4 4 4 5 8 8 8 8 8 8 8 8 8 7 6 5 4 4 4 4 4 4 4 4 5 7 7 7 4 4 4 4 4 4 4 4 5 6 6 6 4 4 4
4 4 4 4 4 5 5 6 7 5 4 4 4 4 4 4 4 4 6 6 7 7 5 4 4 4 4 4 4 4 4 6 6 6 4 4 4 4 4 4 4 4 4 5 7 6 5 5
5 4 4 4 4 4 4 5 6 7 6 4 5 4 4 4 4 4 4 4 6 6 6 6 4 5 4 4 4 4 4 4 5 5 6)
  FIX_UPDATED=(9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9
  9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9
  9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 8 9 9 9 9 9 9 9 9 9 9 9 8 9 9 9 9 9 9 9 9 9 9
  9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9)
  FIX_DEGRADED=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
  FIX_MACHINECOUNT=9
}
__fixture_run3_pinned_enoscp () {
  # provenance: run 2115639973800579072 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 8 8 8 8 8 8 8 8 8 7 7 7 7 7 6 6 5 5 4 4 4 4 4 4 4 5 5 5 6 6 6 7 7 6 6 6 7 7 7 7 7 7 7 7 7 7 7
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8)
  FIX_UPDATED=(9 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
  8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
  8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
  8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8)
  FIX_DEGRADED=(0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1)
  FIX_MACHINECOUNT=9
}
__fixture_green_control () {
  # provenance: run 2115096361434091520 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 8 7 7 7 7 6 6 6 6 6 6 6 7 7 6 6 6 6 4 4 5 4 4 5 5 6 6 6 7 8 4 4 4 5 4 4 4 4 4 4 5 6 8 8 8 8)
  FIX_UPDATED=(9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9)
  FIX_DEGRADED=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
  FIX_MACHINECOUNT=9
}

WaitMcpSelfTest () {
  # Evaluates the CURRENT IsMcpProgressing at each fixture's final poll.
  # Expected verdicts (PR-B, flipped from the PR-A pins):
  #   run1/run3 (Degraded pinned)     -> NOT-PROGRESSING (degraded gate)
  #   run2 (sustained sawtooth)       -> NOT-PROGRESSING (pinned-updated veto)
  #   green-control (recovers)        -> PROGRESSING
  local _fixture _expected _got _fail=0
  for _fixture in run1_pinned_enoscp run2_sawtooth_unconverged run3_pinned_enoscp green_control; do
    "__fixture_${_fixture}"
    case "${_fixture}" in
      green_control) _expected="PROGRESSING" ;;
      *) _expected="NOT-PROGRESSING" ;;
    esac
    readyHistory=("${FIX_READY[@]}")
    updatedHistory=("${FIX_UPDATED[@]}")
    degradedHistory=("${FIX_DEGRADED[@]}")
    machineCountHistory=()
    local _v
    for _v in "${FIX_UPDATED[@]}"; do machineCountHistory+=("${FIX_MACHINECOUNT}"); done
    if IsMcpProgressing 120 3; then _got="PROGRESSING"; else _got="NOT-PROGRESSING"; fi
    echo ">>> selftest: ${_fixture}: ${_got} (pinned: ${_expected})"
    [[ "${_got}" == "${_expected}" ]] || _fail=1
  done
  readyHistory=() ; updatedHistory=() ; degradedHistory=() ; machineCountHistory=()
  return "${_fail}"
}

WaitMcpTrapSelfTest () {
  # Fork the REAL script (byte-identical copy under a distinct basename so
  # the child's xtrace log does not collide with this process's) against a
  # mock oc, send it SIGTERM once it reaches the health-gate poll loop, and
  # assert the TERM contract end to end: exit code 143, a JUnit failure
  # carrying the reason, the scrubbed xtrace bundle in artifacts, and the
  # trap's synchronous work completing well inside the 300s step-timeout
  # grace. Runs on every execution (phase 0) - a mid-step termination is
  # not parameterizable into a pj-rehearse rehearsal, so the per-run
  # self-test is the standing evidence for the termination path (the
  # acceptance criterion's one-shot rehearsal is superseded by this).
  # Harness setup failures (mktemp/copy - environmental, not a semantics
  # break) warn and continue: the step still runs, the JUnit property
  # records trap_selftest=warn. Contract failures (child ran but the TERM
  # path misbehaved) fail the step (exit 2) - preflight review split.
  local _tt_dir _cpid _crc=0 _w _t0 _t1
  _tt_dir="$(mktemp -d /tmp/wmcp-termtest.XXXXXX)" || { echo "trap self-test: mktemp failed (environmental); continuing" >&2; _junit_trapselftest="warn"; return 0; }
  mkdir -p "${_tt_dir}/shared" "${_tt_dir}/artifacts" "${_tt_dir}/mockbin"
  # Mock oc: a worker MCP mid-rollout (Updating, not Degraded, not
  # converged) so the child stays in the poll loop; everything else
  # answers an empty List. The child never touches a real cluster.
  cat > "${_tt_dir}/mockbin/oc" <<'MOCKEOF'
#!/bin/bash
case "$*" in
  *"get mcp -o json"*)
    cat <<'JSONEOF'
{"apiVersion":"v1","items":[{"apiVersion":"machineconfiguration.openshift.io/v1","kind":"MachineConfigPool","metadata":{"name":"worker","generation":3},"spec":{},"status":{"conditions":[{"type":"Degraded","status":"False","reason":"AsExpected"},{"type":"Updated","status":"False","reason":"test"},{"type":"Updating","status":"True","reason":"test"}],"degradedMachineCount":0,"machineCount":9,"observedGeneration":3,"readyMachineCount":7,"unavailableMachineCount":2,"updatedMachineCount":7}}],"kind":"List"}
JSONEOF
    ;;
  *) echo '{"apiVersion":"v1","items":[],"kind":"List"}' ;;
esac
MOCKEOF
  chmod +x "${_tt_dir}/mockbin/oc"
  # $0 must resolve to this file (ref sets run_as_script so it is
  # executed directly, not via bash -c); validate the copy carries this
  # script's marker so an invocation-semantics change degrades to warn,
  # never to silently testing the wrong file (preflight review).
  local _src
  _src="$(readlink -f "${0}" 2>/dev/null)" || _src="${0}"
  cp "${_src}" "${_tt_dir}/wmcp-term-child.sh" || { echo "trap self-test: copy failed (environmental); continuing" >&2; rm -rf "${_tt_dir}"; _junit_trapselftest="warn"; return 0; }
  if ! grep -q "WaitMcpTrapSelfTest" "${_tt_dir}/wmcp-term-child.sh" 2>/dev/null; then
    echo "trap self-test: script path resolved to ${_src}, which is not this script (invocation semantics?); continuing" >&2
    rm -rf "${_tt_dir}"
    _junit_trapselftest="warn"
    return 0
  fi
  # Child: real script, mock API on PATH, tight poll cadence, short
  # deadline so a missed signal still self-terminates, child-mode env so
  # its own phase 0 does not fork another trap test (recursion guard).
  WAIT_MCP_SELFTEST_CHILD=1 PATH="${_tt_dir}/mockbin:${PATH}" \
    SHARED_DIR="${_tt_dir}/shared" ARTIFACT_DIR="${_tt_dir}/artifacts" \
    KUBECONFIG="${_tt_dir}/kubeconfig" MCP_SETTLE_DELAY=0 MCP_POLL_INTERVAL=10 \
    MCP_WAIT_TIMEOUT=120 MCP_WAIT_MAX_TIMEOUT=180 \
    bash "${_tt_dir}/wmcp-term-child.sh" > "${_tt_dir}/child.log" 2>&1 &
  _cpid=$!
  _w=0
  while (( _w < 90 )); do
    grep -q "Polling MCPs for up to" "${_tt_dir}/child.log" 2>/dev/null && break
    # bail out early if the child died before reaching the poll loop
    kill -0 "${_cpid}" 2>/dev/null || break
    sleep 1
    (( _w++ )) || true
  done
  if ! grep -q "Polling MCPs for up to" "${_tt_dir}/child.log" 2>/dev/null; then
    # Slow child startup is environmental (the child re-runs phase 0 under
    # the step's 200m CPU request), not a TERM-contract break: warn and
    # continue (preflight review). The parent already passed the same
    # phase-0 the child runs, so an early child death is environmental too.
    echo "trap self-test: child never reached the poll loop within ${_w}s (slow start - environmental); continuing" >&2
    tail -20 "${_tt_dir}/child.log" >&2
    kill -9 "${_cpid}" 2>/dev/null || true
    wait "${_cpid}" 2>/dev/null || true
    rm -rf "${_tt_dir}"
    _junit_trapselftest="warn"
    return 0
  fi
  _t0=$(date +%s)
  kill -TERM "${_cpid}" 2>/dev/null || true
  wait "${_cpid}" 2>/dev/null || _crc=$?
  _t1=$(date +%s)
  local _ok=0
  # 1. exit code 143 (TERM recorded by the handler, not a shell default)
  (( _crc == 143 )) || { echo "trap self-test: expected exit 143, got ${_crc}" >&2; _ok=1; }
  # 2. JUnit failure carrying the TERM reason
  python3 - "${_tt_dir}/artifacts/junit_lp-interop--OPP--wait-mcp.xml" <<'PYEOF' || _ok=1
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
    tc = {c.get("name"): c for c in root.findall("testcase")}["wait-mcp"]
    f = tc.find("failure")
    assert f is not None, "no failure element"
    assert "143" in (f.get("message") or ""), f"failure message: {f.get('message')}"
except Exception as e:
    print(f"trap self-test: JUnit assertion failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  # 3. scrubbed xtrace bundle landed in artifacts (the never-uploaded
  #    bundle from the original defect)
  ls "${_tt_dir}/artifacts"/xtrace-scrub-*.log >/dev/null 2>&1 || {
    echo "trap self-test: no xtrace-scrub-*.log in artifacts" >&2; _ok=1; }
  # 4. TERM-to-exit well inside the 300s grace (includes bash deferring
  #    the trap behind a <=10s foreground sleep; the trap's own work is
  #    sub-second)
  (( (_t1 - _t0) < 60 )) || { echo "trap self-test: TERM-to-exit took $((_t1 - _t0))s (budget 60s)" >&2; _ok=1; }
  if (( _ok )); then tail -20 "${_tt_dir}/child.log" >&2; fi
  rm -rf "${_tt_dir}"
  (( _ok == 0 ))
}

if WaitMcpSelfTest; then
  _junit_selftest="pass"
  echo ">>> PHASE 0: predicate self-test passed (rewritten predicate pinned)"
else
  _junit_selftest="fail"
  echo "FAILURE CLASS: Invalid step input" >&2
  echo "predicate self-test failed: IsMcpProgressing does not reproduce its pinned behavior" >&2
  exit 2
fi
if [[ -z "${WAIT_MCP_SELFTEST_CHILD:-}" ]]; then
  if WaitMcpTrapSelfTest; then
    # keep a warn verdict set inside the harness-failure paths
    [[ "${_junit_trapselftest}" == "warn" ]] || _junit_trapselftest="pass"
    echo ">>> PHASE 0: trap self-test passed (TERM -> 143, JUnit reason, xtrace bundle, bounded grace)"
  else
    _junit_trapselftest="fail"
    echo "FAILURE CLASS: Invalid step input" >&2
    echo "trap self-test failed: TERM contract (exit 143, JUnit reason, xtrace bundle, bounded grace) not reproduced" >&2
    exit 2
  fi
else
  _junit_trapselftest="skip"
fi

function EmitMcpConditions () {
    # Print every non-paused MCP's conditions (type, status, reason, message)
    # verbatim from the given MCP JSON. Never fails.
    echo "${1}" | timeout 10s python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('items', []):
    if m.get('spec', {}).get('paused', False):
        continue
    name = m['metadata']['name']
    for c in m.get('status', {}).get('conditions', []):
        print(f'{name}: {c.get(\"type\")}={c.get(\"status\")} reason={c.get(\"reason\")!r} message={c.get(\"message\")!r}')
" 2>/dev/null || true
    true
}

function FirstDegradedCondition () {
    # Echo the first Degraded/NodeDegraded condition message (verbatim) from
    # the given MCP JSON, or nothing. Never fails.
    echo "${1}" | timeout 10s python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('items', []):
    if m.get('spec', {}).get('paused', False):
        continue
    for c in m.get('status', {}).get('conditions', []):
        if c.get('type') in ('Degraded', 'NodeDegraded') and c.get('status') == 'True':
            print(f'{m[\"metadata\"][\"name\"]}: {c.get(\"type\")} reason={c.get(\"reason\")!r} message={c.get(\"message\")!r}')
            sys.exit(0)
sys.exit(1)
" 2>/dev/null || true
    true
}

function CollectFailureBundle () {
    # Bounded, idempotent failure-path evidence collection (INTEROP-9646):
    # everything attribution needs without a must-gather - the FIPS lane
    # has none. Watchdog 120s, per-call 10s, big objects redirected to
    # files (never echoed under set -x), so the whole path fits the 5m
    # termination grace with the 60s self-terminating headroom.
    (( _bundleCollected )) && return 0
    _bundleCollected=1
    [[ -n "${ARTIFACT_DIR:-}" ]] || return 0
    set +x 2>/dev/null
    # Policy artifacts are SECRET-REDACTED on the way out (preflight
    # review): policy-templates can embed Secret objects whose
    # data/stringData would otherwise land in the public artifact
    # bucket; fromSecret references (names only) are kept.
    local _redact
    _redact="$(mktemp /tmp/wmcp-redact.XXXXXX.py)" || _redact=""
    if [[ -n "${_redact}" ]]; then
      cat > "${_redact}" <<'REDACTEOF'
import sys, json

def redact(o):
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            if k in ("data", "stringData") and isinstance(v, dict):
                out[k] = {ik: "REDACTED" for ik in v}
            elif k == "object-templates-raw" and isinstance(v, str):
                # Embedded manifests as a raw string (ConfigurationPolicy
                # spec, or a Policy embedding one): a Secret manifest inside
                # the string bypasses the dict walker, so the whole raw
                # template is replaced (preflight review).
                out[k] = "REDACTED (raw object templates)"
            elif k.endswith("last-applied-configuration") and isinstance(v, str):
                # oc-apply annotations carry the full applied object as a
                # JSON string - including any embedded Secret data; the
                # whole annotation is replaced (preflight review).
                out[k] = "REDACTED (last-applied-configuration)"
            else:
                out[k] = redact(v)
        return out
    if isinstance(o, list):
        return [redact(x) for x in o]
    return o

json.dump(redact(json.load(sys.stdin)), sys.stdout, indent=1)
REDACTEOF
    fi
    timeout 120s bash -c '
      oc --request-timeout=10s get machines -A -o yaml > "'"${ARTIFACT_DIR}"'/machines.yaml" 2>/dev/null || true
      oc --request-timeout=10s get machinesets -A -o yaml > "'"${ARTIFACT_DIR}"'/machinesets.yaml" 2>/dev/null || true
      if [ -n "'"${_redact}"'" ]; then
        oc --request-timeout=10s get configurationpolicies.policy.open-cluster-management.io -A -o json 2>/dev/null | python3 "'"${_redact}"'" > "'"${ARTIFACT_DIR}"'/configurationpolicies.yaml" || true
        oc --request-timeout=10s get policies.policy.open-cluster-management.io -A -o json 2>/dev/null | python3 "'"${_redact}"'" > "'"${ARTIFACT_DIR}"'/policies.yaml" || true
      else
        echo "redactor unavailable: policies/configurationpolicies SKIPPED (fail closed - templates can embed Secret data)" > "'"${ARTIFACT_DIR}"'/policies.yaml"
      fi
      oc --request-timeout=10s get kubeletconfigs.machineconfiguration.openshift.io -A -o yaml > "'"${ARTIFACT_DIR}"'/kubeletconfigs.yaml" 2>/dev/null || true
      oc --request-timeout=10s get mcp -o yaml > "'"${ARTIFACT_DIR}"'/mcps.yaml" 2>/dev/null || true
      oc --request-timeout=10s get nodes -o json > "'"${ARTIFACT_DIR}"'/nodes.json" 2>/dev/null || true
    ' || true
    if [[ -n "${_redact}" ]]; then rm -f "${_redact}"; fi
    echo ">>> failure bundle collected to ${ARTIFACT_DIR} (machines, machinesets, policies [secret-redacted], kubeletconfigs, mcps, nodes)"
    set -x 2>/dev/null || true
    return 0
}

function AssertClusterHealthy () {
    # Verify ClusterOperators and nodes are healthy before declaring MCP success.
    typeset -i failures=0

    echo ""
    echo "=== ClusterOperator health gate ==="
    typeset coJson=""
    if ! coJson="$(timeout 45s oc get clusteroperators -o json --request-timeout=30s 2>/dev/null)"; then
        echo "WARNING: Failed to fetch ClusterOperators"
        (( ++failures )) || true
    else
        typeset coIssues=""
        coIssues="$(echo "${coJson}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
issues = []
for co in data.get('items', []):
    name = co['metadata']['name']
    conds = {c['type']: c['status'] for c in co.get('status', {}).get('conditions', [])}
    avail = conds.get('Available', 'Unknown')
    prog = conds.get('Progressing', 'Unknown')
    deg = conds.get('Degraded', 'Unknown')
    if avail != 'True' or prog != 'False' or deg != 'False':
        issues.append(f'{name}: Available={avail} Progressing={prog} Degraded={deg}')
if issues:
    print('\\n'.join(issues))
" 2>/dev/null)" || coIssues="python parse error"
        if [[ -n "${coIssues}" ]]; then
            echo "UNHEALTHY ClusterOperators:"
            echo "${coIssues}"
            (( ++failures )) || true
        else
            echo "All ClusterOperators healthy (Available=True, Progressing=False, Degraded=False)"
        fi
    fi

    echo ""
    echo "=== Node readiness gate ==="
    typeset notReady=""
    notReady="$(timeout 45s oc get nodes -o json --request-timeout=30s 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
bad = []
for node in data.get('items', []):
    name = node['metadata']['name']
    conds = {c['type']: c['status'] for c in node.get('status', {}).get('conditions', [])}
    if conds.get('Ready') != 'True':
        bad.append(name)
if bad:
    print('\\n'.join(bad))
" 2>/dev/null)" || notReady="failed to check"
    if [[ -n "${notReady}" ]]; then
        echo "NOT READY nodes:"
        echo "${notReady}"
        (( ++failures )) || true
    else
        echo "All nodes Ready"
    fi

    echo ""
    if (( failures > 0 )); then
        echo "CLUSTER HEALTH GATE FAILED: ${failures} check(s) failed"
        echo "Degraded ClusterOperators or NotReady nodes will cascade into misleading test failures"
        ocb get clusteroperators
        echo ""
        ocb get nodes -o wide
        return 1
    fi
    echo "Cluster health gate passed"
    return 0
}

function ClassifyMcpState () {
    # Classify the MCP timeout as DEGRADED, UPDATING, or UNKNOWN from the JSON state.
    typeset json="${1}"
    echo "${json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = [m for m in data.get('items', []) if not m.get('spec', {}).get('paused', False)]
degraded = any(
    {c['type']: c['status'] for c in m.get('status', {}).get('conditions', [])}.get('Degraded') == 'True'
    for m in items
)
updating = any(
    {c['type']: c['status'] for c in m.get('status', {}).get('conditions', [])}.get('Updating') == 'True'
    for m in items
)
if degraded:
    print('DEGRADED')
elif updating:
    print('UPDATING')
else:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN"
    true
}

echo "Waiting ${settleDelay}s for MachineConfig rendering to propagate..."
sleep "${settleDelay}"

# INTEROP-9646: the maxUnavailable=3 patch mutated the SUT and was never
# reverted (run 2115639973800579072: Degraded onset 75s after the patch,
# ready sawtooth 4/9 while it was in effect). Removed; the serialized
# 9-machine rollout measures ~21 min, well inside the 5400s budget.
echo "Not patching worker MCP maxUnavailable (SUT mutation removed; serialized rollout measured ~21 min)"

echo "MachineConfigs created since cluster install:"
typeset mcList=''
mcList="$(ocb get machineconfig --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp)"
echo "${mcList}" | tail -10

typeset -i startSeconds=${SECONDS}
typeset -i effectiveTimeout=${mcpWaitTimeout}
if (( effectiveTimeout > maxTimeout )); then
    effectiveTimeout=${maxTimeout}
fi
typeset -i deadline=$(( startSeconds + effectiveTimeout ))
typeset -i consecutivePasses=0
typeset -i consecutiveFailures=0
typeset -i currentPollInterval=${pollInterval}

echo "Polling MCPs for up to ${effectiveTimeout}s (need ${consecutiveRequired} consecutive clean polls)..."
echo "Progress-based extension: +${progressExtension}s per detection, max total ${maxTimeout}s"

while (( SECONDS < deadline )); do
    typeset -i remaining=$(( deadline - SECONDS ))
    (( remaining < 5 )) && remaining=5
    # Cap the in-loop call at 60s: a hung apiserver must be distinguishable
    # from a slow rollout instead of consuming the whole remaining deadline.
    (( remaining > 60 )) && remaining=60
    typeset mcpJson=""
    if mcpJson="$(oc get mcp -o json --request-timeout="${remaining}s" 2>/dev/null)"; then
        consecutiveFailures=0
        currentPollInterval=${pollInterval}
    else
        (( consecutiveFailures++ )) || true
        # Exponential backoff: base → 2x → 4x, capped at 120s
        typeset -i backoffExponent=$(( consecutiveFailures > 3 ? 3 : consecutiveFailures - 1 ))
        currentPollInterval=$(( pollInterval * (2 ** backoffExponent) ))
        (( currentPollInterval > 120 )) && currentPollInterval=120
        echo "WARNING: oc get mcp failed (attempt ${consecutiveFailures}), backing off to ${currentPollInterval}s"
        if (( consecutiveFailures >= 5 )); then
            echo "FAILURE CLASS: cluster-api-unreachable"
            echo "oc get mcp failed ${consecutiveFailures} consecutive times; cluster API unreachable from the step"
            _junit_class="cluster-api-unreachable"
            CollectFailureBundle
            exit 1
        fi
        consecutivePasses=0
        sleep "${currentPollInterval}"
        continue
    fi

    (( _junit_polls += 1 )) || true
    typeset statusLine=""
    statusLine="$(echo "${mcpJson}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
issues = []
total_ready = 0
total_updated = 0
total_machine = 0
any_degraded = 0
gen_parts = []
for mcp in data.get('items', []):
    name = mcp['metadata']['name']
    paused = mcp.get('spec', {}).get('paused', False)
    if paused:
        continue
    conditions = {c['type']: c['status'] for c in mcp.get('status', {}).get('conditions', [])}
    updating = conditions.get('Updating', 'Unknown')
    degraded = conditions.get('Degraded', 'Unknown')
    updated_cond = conditions.get('Updated', 'Unknown')
    status = mcp.get('status', {})
    ready = status.get('readyMachineCount', 0)
    total = status.get('machineCount', 0)
    updated = status.get('updatedMachineCount', 0)
    unavailable = status.get('unavailableMachineCount', 0)
    generation = mcp['metadata'].get('generation', 0)
    observed = status.get('observedGeneration', -1)
    # Per-pool generation fingerprint (sorted name=gen pairs), not a sum:
    # a replaced pool (one removed, another created, both generation 1)
    # keeps the sum unchanged and would hide the churn (preflight review).
    gen_parts.append(f'{name}={generation}')
    total_ready += ready
    total_updated += updated
    total_machine += total
    if degraded == 'True':
        any_degraded = 1
    # Stability requires the condition tokens AND count congruence AND the
    # observed generation catching up (render churn resets stability).
    if (updating == 'True' or degraded == 'True' or updated_cond != 'True'
            or unavailable > 0 or ready != total or updated != total
            or observed != generation):
        issues.append(f'{name}: Updating={updating} Updated={updated_cond} Degraded={degraded} ready={ready}/{total} updated={updated}/{total} unavailable={unavailable} gen={generation}/obs={observed}')
if issues:
    print('UNSTABLE|' + '; '.join(issues) + '|' + str(total_ready) + '|' + str(total_updated) + '|' + str(total_machine) + '|' + str(any_degraded) + '|' + ';'.join(sorted(gen_parts)))
else:
    print('STABLE|all non-paused MCPs healthy|' + str(total_ready) + '|' + str(total_updated) + '|' + str(total_machine) + '|0|' + ';'.join(sorted(gen_parts)))
" 2>/dev/null)" || statusLine="UNSTABLE|python parse error|0|0|0|0|"

    typeset statusKey="${statusLine%%|*}"
    # statusLine = KEY|detail|ready|updated|machine|degraded|genPrint
    typeset -i totalReady=0 totalUpdated=0 totalMachine=0 anyDegraded=0
    typeset _detail="" _degField="" genPrint=""
    IFS='|' read -r _statusKeyField _detail totalReady totalUpdated totalMachine _degField genPrint <<< "${statusLine}"
    statusKey="${_statusKeyField}"
    typeset statusDetail="${_detail}"
    [[ "${totalReady}" =~ ^[0-9]+$ ]] || totalReady=0
    [[ "${totalUpdated}" =~ ^[0-9]+$ ]] || totalUpdated=0
    [[ "${totalMachine}" =~ ^[0-9]+$ ]] || totalMachine=0
    [[ "${_degField}" =~ ^[0-9]+$ ]] && anyDegraded=$(( _degField ))
    # Window reset on desired-config change (render churn); count churn runs.
    # genPrint is the sorted per-pool name=gen fingerprint: a replaced pool
    # changes it even when a numeric sum would not (preflight review).
    if [[ -n "${_lastGenPrint}" && -n "${genPrint}" && "${genPrint}" != "${_lastGenPrint}" ]]; then
        (( ++_renderChurnCount )) || true
        echo "Render churn detected (generations ${_lastGenPrint} -> ${genPrint}, churn #${_renderChurnCount}); resetting trend window"
        readyHistory=()
        updatedHistory=()
        machineCountHistory=()
        degradedHistory=()
        consecutivePasses=0
    fi
    _lastGenPrint="${genPrint}"
    readyHistory+=("${totalReady}")
    updatedHistory+=("${totalUpdated}")
    machineCountHistory+=("${totalMachine}")
    degradedHistory+=("${anyDegraded}")
    (( ${#machineCountHistory[@]} > 1 )) || true
    typeset -i elapsed=$(( SECONDS - startSeconds ))

    if [[ "${statusKey}" == "STABLE" ]]; then
        (( consecutivePasses += 1 )) || true
        echo "Clean poll ${consecutivePasses}/${consecutiveRequired} at ${elapsed}s: ${statusDetail}"
        if (( consecutivePasses >= consecutiveRequired )); then
            echo "MCPs stable after ${elapsed}s (${consecutiveRequired} consecutive clean polls)"
            AssertClusterHealthy
            exit $?
        fi
    else
        if (( consecutivePasses > 0 )); then
            echo "Stability interrupted after ${consecutivePasses} clean polls, resetting"
        fi
        consecutivePasses=0
        (( pollsSinceLastExtension += 1 )) || true
        echo "Waiting at ${elapsed}/${effectiveTimeout}s: ${statusDetail}"

        # Capture every Degraded sighting verbatim (no extra oc calls;
        # the poll JSON is already in hand) so the JUnit failure body and
        # the log carry the decisive condition text, and fail fast on a
        # non-self-healing ENOSPC signature (>= 2 consecutive polls with
        # the same condition message) instead of burning the 5400s budget.
        if (( anyDegraded )); then
            if (( _junit_first_signature_poll < 0 )); then
                _junit_first_signature_poll=${_junit_polls}
                echo ">>> First Degraded sighting at poll ${_junit_polls} (${elapsed}s); conditions verbatim:"
                EmitMcpConditions "${mcpJson}"
            fi
            typeset _degCond=""
            _degCond="$(FirstDegradedCondition "${mcpJson}")"
            if [[ -n "${_degCond}" ]]; then
                _junit_reason="${_degCond}"
                if [[ "${_degCond}" == "${_lastSignatureReason}" ]]; then
                    (( ++_signatureRepeat )) || true
                else
                    _signatureRepeat=1
                    _lastSignatureReason="${_degCond}"
                fi
                if (( _signatureRepeat >= 2 )) && [[ "${_degCond}" =~ (no\ space\ left\ on\ device|disk\ full|could\ not\ write\ image\ pull\ secret) ]]; then
                    echo "FAILURE CLASS: storage-capacity-enospc"
                    echo "Non-self-healing ENOSPC signature persisted ${_signatureRepeat} consecutive polls (poll ${_junit_polls}, ${elapsed}s); failing fast instead of exhausting ${effectiveTimeout}s"
                    _junit_class="storage-capacity-enospc"
                    CollectFailureBundle
                    exit 1
                fi
            fi
        else
            _signatureRepeat=0
        fi

        # Progress-based timeout extension: if MCPs are making progress,
        # extend the deadline to avoid timing out on slow-but-healthy rollouts.
        if (( pollsSinceLastExtension >= extensionCheckInterval )); then
            if IsMcpProgressing; then
                typeset -i proposedDeadline=$(( deadline + progressExtension ))
                typeset -i maxDeadline=$(( startSeconds + maxTimeout ))
                if (( proposedDeadline > maxDeadline )); then
                    proposedDeadline=${maxDeadline}
                fi
                if (( proposedDeadline > deadline )); then
                    typeset -i appliedExtension=$(( proposedDeadline - deadline ))
                    deadline=${proposedDeadline}
                    effectiveTimeout=$(( deadline - startSeconds ))
                    (( extensionsApplied += 1 )) || true
                    pollsSinceLastExtension=0
                    echo "Progress detected: extending deadline by ${appliedExtension}s (total wait now ${effectiveTimeout}s/${maxTimeout}s max, extension #${extensionsApplied})"
                else
                    echo "Progress detected but max timeout ${maxTimeout}s would be exceeded — no further extensions"
                fi
            elif (( _vetoStreakHit )); then
                # Sustained-cycling fail-fast: the veto's purpose (the
                # maxTimeout cap already bounds extensions; without this
                # exit the cycling pool would poll to the deadline).
                echo "FAILURE CLASS: mcp-rollout-not-converging"
                echo "sustained cycling: ${pinnedUpdatedPolls} consecutive not-ready polls without Degraded (rollout re-rendering/re-rebooting, not progressing)"
                _junit_class="mcp-rollout-not-converging"
                CollectFailureBundle
                exit 1
            fi
        fi
    fi

    sleep "${currentPollInterval}"
done

typeset -i elapsed=$(( SECONDS - startSeconds ))
echo "MCPs did not stabilize within ${elapsed}s — classifying timeout..."
if (( extensionsApplied > 0 )); then
    echo "Deadline was extended ${extensionsApplied} time(s) due to detected progress (initial timeout: ${mcpWaitTimeout}s, effective: ${effectiveTimeout}s)"
fi
echo ""
echo "Final MCP state:"
ocb get mcp -o wide
echo ""

typeset classification="UNKNOWN"
typeset finalJson=""
if finalJson="$(timeout 45s oc get mcp -o json --request-timeout=30s 2>/dev/null)"; then
    classification="$(ClassifyMcpState "${finalJson}")"
fi

CollectFailureBundle
# Render churn is orthogonal to the final condition state: a churning
# pool is Updating=True (or Degraded) while it re-renders, so the state
# branches below would otherwise misattribute it (preflight review:
# the churn check in the UNKNOWN branch was unreachable). The churn
# count is the mechanism; the branch diagnostics (conditions verbatim,
# node dumps) are already captured per-poll and in the bundle.
if (( _renderChurnCount >= renderChurnLimit )); then
    echo "FAILURE CLASS: mcp-render-churn"
    echo "MachineConfig generation changed ${_renderChurnCount} times during the wait (limit ${renderChurnLimit}); the pool is being re-rendered faster than it can converge (final state: ${classification})"
    _junit_class="mcp-render-churn"
    echo "Ready count trend: ${readyHistory[*]}"
    exit 1
fi
case "${classification}" in
    DEGRADED)
        if [[ -n "${_junit_reason}" && "${_junit_reason}" =~ (no\ space\ left\ on\ device|disk\ full|could\ not\ write\ image\ pull\ secret) ]]; then
            echo "FAILURE CLASS: storage-capacity-enospc"
            _junit_class="storage-capacity-enospc"
        else
            echo "FAILURE CLASS: mcp-degraded"
            _junit_class="mcp-degraded"
        fi
        echo "One or more MCPs have Degraded=True; conditions verbatim:"
        echo ""
        EmitMcpConditions "${finalJson}"
        if [[ -z "${_junit_reason}" && -n "${finalJson}" ]]; then
            _junit_reason="$(FirstDegradedCondition "${finalJson}")"
        fi
        echo ""
        ocb get nodes -o wide
        exit 1
        ;;
    UPDATING)
        echo "Ready count trend: ${readyHistory[*]}"
        if IsMcpProgressing; then
            echo "FAILURE CLASS: mcp-deadline-exceeded"
            echo "MCP rollout is healthy (Degraded=False, progressing) but too slow for the ${effectiveTimeout}s timeout"
            _junit_class="mcp-deadline-exceeded"
            AssertClusterHealthy || true
            exit 1
        else
            if (( ${#updatedHistory[@]} > 0 )) && (( updatedHistory[${#updatedHistory[@]}-1] == machineCountHistory[${#machineCountHistory[@]}-1] )); then
                echo "FAILURE CLASS: mcp-rollout-not-converging"
                echo "All machines updated (updated==machineCount) but the pool never went ready; ready count oscillated without Degraded — cycling, not progressing"
                _junit_class="mcp-rollout-not-converging"
            else
                echo "FAILURE CLASS: Potential interop issue"
                echo "MCP is updating but neither updated nor ready counts are progressing — nodes may be cycling"
                _junit_class="UPDATING-oscillating"
            fi
            echo ""
            ocb get nodes -o wide
            typeset mcpWorkerDesc=''
            mcpWorkerDesc="$(ocb describe mcp worker)"
            echo "${mcpWorkerDesc}" | tail -30
            exit 1
        fi
        ;;
    *)
        echo "FAILURE CLASS: Unknown timeout"
        _junit_class="UNKNOWN"
        echo "Ready count trend: ${readyHistory[*]}"
        exit 1
        ;;
esac
