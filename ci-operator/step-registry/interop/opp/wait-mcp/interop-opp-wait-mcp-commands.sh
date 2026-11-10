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
    tail -c 5242880 "${_xtrace_log}" > "${_scrub}" 2>/dev/null || true
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
  # XML-escape via sed: bash >= 5.2 patsub_replacement expands a bare & in
  # ${var//pat/repl} to the matched text (breaking &lt; into <lt;), and older
  # bash keeps a backslash literally - sed's \& is unambiguous everywhere.
  local _esc_reason
  _esc_reason=$(printf '%s' "${_junit_reason}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
  local _esc_class
  _esc_class=$(printf '%s' "${_junit_class}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
  if (( _jr != 0 )); then
    _fc=1
    _fx="<failure message=\"${_jn} exited with code ${_jr}${_esc_class:+: ${_esc_class}}\" type=\"StepFailure\">${_jn} exited with code ${_jr}.${_esc_reason:+ Verbatim condition: ${_esc_reason}}</failure>"
  fi
  local _st_fc=0 _st_fx=""
  if [[ "${_junit_selftest}" == "fail" ]]; then
    _st_fc=1
    _st_fx="<failure message=\"predicate self-test failed\" type=\"SelfTestFailure\">Offline predicate self-test failed; step semantics are not the reviewed ones.</failure>"
  fi
  cat > "${_jf}" <<JUNITEOF || true
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="lp-interop--OPP--${_jn}" tests="2" failures="$((_fc + _st_fc))" errors="0" skipped="0" time="${_jd}">
  <properties>
    <property name="polls" value="${_junit_polls}"/>
    <property name="extensions" value="${extensionsApplied}"/>
    <property name="mcp_wait_seconds" value="${_jd}"/>
    <property name="first_signature_poll" value="${_junit_first_signature_poll}"/>
    <property name="final_class" value="${_esc_class}"/>
  </properties>
  <testcase name="predicate-selftest" classname="lp-interop.OPP.${_jn}" time="0">
    ${_st_fx}
  </testcase>
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
  if ! [[ "${_raw}" =~ ^[0-9]+$ ]] || (( _raw < _min )); then
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

typeset -ri mcpWaitTimeout="${MCP_WAIT_TIMEOUT:-3600}"
typeset -ri progressExtension="${MCP_WAIT_PROGRESS_EXTENSION:-1200}"
typeset -ri maxTimeout="${MCP_WAIT_MAX_TIMEOUT:-5400}"
typeset -ri consecutiveRequired="${MCP_CONSECUTIVE_CHECKS:-3}"
typeset -ri settleDelay="${MCP_SETTLE_DELAY:-90}"
typeset -ri maxUnavailable="${MCP_MAX_UNAVAILABLE:-3}"
typeset -ri pollInterval="${MCP_POLL_INTERVAL:-30}"
typeset -a readyHistory=()
typeset -i extensionsApplied=0
typeset -i pollsSinceLastExtension=0
typeset -ri extensionCheckInterval=5
typeset -i _junit_polls=0
typeset -i _junit_first_signature_poll=-1

function IsReadyCountProgressing () {
    # Check if the MCP ready count is trending upward over the last 6 polls.
    # (Byte-identical extraction target for the offline self-test below.)
    typeset -i len=${#readyHistory[@]}
    (( len < 3 )) && return 1
    typeset -i windowStart=$(( len > 6 ? len - 6 : 0 ))
    typeset -i first=${readyHistory[windowStart]}
    typeset -i last=${readyHistory[len - 1]}
    typeset -i decreases=0
    for (( i = windowStart + 1; i < len; ++i )); do
        (( readyHistory[i] < readyHistory[i-1] )) && (( ++decreases )) || true
    done
    if (( last > first && decreases <= 1 )); then
        return 0
    fi
    return 1
}

# --- Offline predicate self-test (phase 0) ---------------------------------
# Fixtures are per-poll records (ready, updated, degraded) extracted from
# real runs' interop-opp-wait-mcp build logs (prow, ocp-4.22 CR full-stack):
#   run1-pinned-enospc      2115277579970678784  Degraded pinned, ENOSPC
#   run2-sawtooth           2115458776726245376  updated=9/9, ready sawtooth
#   run3-pinned-enospc      2115639973800579072  Degraded pinned, ENOSPC
#   green-control           2115096361434091520  converged after churn
# This test PINS THE CURRENT PREDICATE: a failure means the extraction or a
# refactor changed step semantics. (The current predicate grants a progress
# extension on all four series - including both Degraded-pinned runs and the
# sawtooth - which is the defect PR-B fixes; the expectations flip there.)

__fixture_run1_pinned_enoscp () {
  # provenance: run 2115277579970678784 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 7 7 7 7 7 6 6 6 6 6 7 7 7 7 7 7 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8)
}
__fixture_run2_sawtooth_unconverged () {
  # provenance: run 2115458776726245376 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 7 7 7 7 6 6 6 6 6 7 7 7 7 7 8 8 8 8 7 6 6 5 4 4 4 4 5 4 4 4 4 5 5 5 5 5 4 4 6 7 7 8 8 8 6 5 5
4 5 4 4 4 4 4 4 5 8 8 8 8 8 8 8 8 8 7 6 5 4 4 4 4 4 4 4 4 5 7 7 7 4 4 4 4 4 4 4 4 5 6 6 6 4 4 4
4 4 4 4 4 5 5 6 7 5 4 4 4 4 4 4 4 4 6 6 7 7 5 4 4 4 4 4 4 4 4 6 6 6 4 4 4 4 4 4 4 4 4 5 7 6 5 5
5 4 4 4 4 4 4 5 6 7 6 4 5 4 4 4 4 4 4 4 6 6 6 6 4 5 4 4 4 4 4 4 5 5 6)
}
__fixture_run3_pinned_enoscp () {
  # provenance: run 2115639973800579072 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 8 8 8 8 8 8 8 8 8 7 7 7 7 7 6 6 5 5 4 4 4 4 4 4 4 5 5 5 6 6 6 7 7 6 6 6 7 7 7 7 7 7 7 7 7 7 7
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8
8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 8)
}
__fixture_green_control () {
  # provenance: run 2115096361434091520 (prow ocp-4.22 CR full-stack), artifact
  # interop-opp-wait-mcp/build-log.txt; per-poll worker readyMachineCount
  FIX_READY=(8 8 7 7 7 7 6 6 6 6 6 6 6 7 7 6 6 6 6 4 4 5 4 4 5 5 6 6 6 7 8 4 4 4 5 4 4 4 4 4 4 5 6 8 8 8 8)
}

WaitMcpSelfTest () {
  # Runs the CURRENT IsReadyCountProgressing over each fixture with
  # any-window extension semantics (the loop evaluates the predicate every
  # extensionCheckInterval polls on the growing history). Expected verdicts
  # record the current behavior: extension granted on all four fixtures.
  local _fixture _expected _got _fail=0
  for _fixture in run1_pinned_enoscp run2_sawtooth_unconverged run3_pinned_enoscp green_control; do
    "__fixture_${_fixture}"
    _expected="GRANTED"
    _got="NOT-GRANTED"
    local -a _hist=()
    local _v
    for _v in "${FIX_READY[@]}"; do
      _hist+=("${_v}")
      local -a _win=("${_hist[@]:$((${#_hist[@]} > 6 ? ${#_hist[@]} - 6 : 0))}")
      readyHistory=("${_win[@]}")
      if IsReadyCountProgressing; then _got="GRANTED"; break; fi
    done
    echo ">>> selftest: ${_fixture}: extension=${_got} (pinned: ${_expected})"
    [[ "${_got}" == "${_expected}" ]] || _fail=1
  done
  readyHistory=()
  return "${_fail}"
}

if WaitMcpSelfTest; then
  _junit_selftest="pass"
  echo ">>> PHASE 0: predicate self-test passed (current behavior pinned)"
else
  _junit_selftest="fail"
  echo "FAILURE CLASS: Invalid step input" >&2
  echo "predicate self-test failed: extracted IsReadyCountProgressing does not reproduce its pinned behavior" >&2
  exit 2
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

function AssertClusterHealthy () {
    # Verify ClusterOperators and nodes are healthy before declaring MCP success.
    typeset -i failures=0

    echo ""
    echo "=== ClusterOperator health gate ==="
    typeset coJson=""
    if ! coJson="$(oc get clusteroperators -o json --request-timeout=30s 2>/dev/null)"; then
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
    notReady="$(oc get nodes -o json --request-timeout=30s 2>/dev/null | python3 -c "
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

echo "Patching worker MCP maxUnavailable=${maxUnavailable} to parallelize node rollout..."
if oc patch machineconfigpool worker --type merge -p "{\"spec\":{\"maxUnavailable\": ${maxUnavailable}}}" --request-timeout=10s 2>/dev/null; then
    echo "Worker MCP maxUnavailable set to ${maxUnavailable}"
else
    echo "WARNING: Failed to patch maxUnavailable (may not have permission or MCP may not exist)"
fi

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
for mcp in data.get('items', []):
    name = mcp['metadata']['name']
    paused = mcp.get('spec', {}).get('paused', False)
    if paused:
        continue
    conditions = {c['type']: c['status'] for c in mcp.get('status', {}).get('conditions', [])}
    updating = conditions.get('Updating', 'Unknown')
    degraded = conditions.get('Degraded', 'Unknown')
    status = mcp.get('status', {})
    ready = status.get('readyMachineCount', 0)
    total = status.get('machineCount', 0)
    updated = status.get('updatedMachineCount', 0)
    unavailable = status.get('unavailableMachineCount', 0)
    total_ready += ready
    if updating == 'True' or degraded == 'True' or unavailable > 0 or ready != total or updated != total:
        issues.append(f'{name}: Updating={updating} Degraded={degraded} ready={ready}/{total} updated={updated}/{total} unavailable={unavailable}')
if issues:
    print('UNSTABLE|' + '; '.join(issues) + '|' + str(total_ready))
else:
    print('STABLE|all non-paused MCPs healthy|' + str(total_ready))
" 2>/dev/null)" || statusLine="UNSTABLE|python parse error|0"

    typeset statusKey="${statusLine%%|*}"
    typeset remainder="${statusLine#*|}"
    typeset statusDetail="${remainder%|*}"
    typeset -i totalReady=0
    totalReady="${remainder##*|}" 2>/dev/null || totalReady=0
    readyHistory+=("${totalReady}")
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

        # Capture the first Degraded sighting verbatim (no extra oc calls;
        # the poll JSON is already in hand) so the JUnit failure body and
        # the log carry the decisive condition text.
        if (( _junit_first_signature_poll < 0 )) && [[ "${statusDetail}" == *"Degraded=True"* ]]; then
            _junit_first_signature_poll=${_junit_polls}
            echo ">>> First Degraded sighting at poll ${_junit_polls} (${elapsed}s); conditions verbatim:"
            EmitMcpConditions "${mcpJson}"
            typeset _firstDeg=""
            _firstDeg="$(FirstDegradedCondition "${mcpJson}")"
            if [[ -n "${_firstDeg}" ]]; then
            _junit_reason="${_firstDeg}"
            fi
        fi

        # Progress-based timeout extension: if MCPs are making progress,
        # extend the deadline to avoid timing out on slow-but-healthy rollouts.
        if (( pollsSinceLastExtension >= extensionCheckInterval )); then
            if IsReadyCountProgressing; then
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
if finalJson="$(oc get mcp -o json --request-timeout=30s 2>/dev/null)"; then
    classification="$(ClassifyMcpState "${finalJson}")"
fi

case "${classification}" in
    DEGRADED)
        echo "FAILURE CLASS: Product interop failure"
        echo "One or more MCPs have Degraded=True; conditions verbatim:"
        echo ""
        EmitMcpConditions "${finalJson}"
        if [[ -z "${_junit_reason}" && -n "${finalJson}" ]]; then
            _junit_reason="$(FirstDegradedCondition "${finalJson}")"
        fi
        _junit_class="DEGRADED"
        echo ""
        ocb get nodes -o wide
        exit 1
        ;;
    UPDATING)
        echo "Ready count trend: ${readyHistory[*]}"
        if IsReadyCountProgressing; then
            echo "FAILURE CLASS: Infrastructure timeout"
            echo "MCP rollout is healthy (Degraded=False, ready count increasing) but too slow for the ${effectiveTimeout}s timeout"
            _junit_class="UPDATING-progressing"
            AssertClusterHealthy || true
            exit 1
        else
            echo "FAILURE CLASS: Potential interop issue"
            echo "MCP is updating but ready count is not progressing — nodes may be cycling"
            _junit_class="UPDATING-oscillating"
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
