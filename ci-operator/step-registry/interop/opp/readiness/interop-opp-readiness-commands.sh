#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
_opp_cleanup() {
  _exit_code=$?
  set +x 2>/dev/null
  # Scrub credentials before copying
  sed -i -E \
    -e 's/(password|token|secret|key|credential)=[^ ]*/\1=REDACTED/gi' \
    -e 's/Bearer [A-Za-z0-9._~+\/=-]+/Bearer [REDACTED]/g' \
    -e 's/password=[^ &]+/password=[REDACTED]/g' \
    -e 's/token=[^ &]+/token=[REDACTED]/g' \
    -e 's|://[^:@/]*:[^:@/]*@|://[REDACTED]:[REDACTED]@|g' \
    "${_xtrace_log}" 2>/dev/null || true
  if [[ ${_exit_code} -ne 0 && -n "${ARTIFACT_DIR:-}" ]]; then
    cp "${_xtrace_log}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    echo ">>> TRACE: xtrace log saved to artifacts (exit code ${_exit_code})"
  fi
}

# --- JUnit XML wrapper: emit result for skip-ratio-gate ---
_junit_start=$(date +%s)
_junit_emitted=0
_jrc=0
_junit_emit() {
  (( _junit_emitted )) && return 0
  _junit_emitted=1
  local _jr=${1:-0}
  local _je
  _je=$(date +%s) || _je=${_junit_start}
  local _jd=$((_je - _junit_start))
  local _jn="readiness"
  local _jf="${ARTIFACT_DIR:-/tmp}/junit_lp-interop--OPP--${_jn}.xml"
  local _fc=0 _fx=""
  if (( _jr != 0 )); then
    _fc=1
    _fx="<failure message=\"${_jn} exited with code ${_jr}\" type=\"StepFailure\">Step exited with code ${_jr}</failure>"
  fi
  cat > "${_jf}" <<JUNITEOF || true
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="lp-interop--OPP--${_jn}" tests="1" failures="${_fc}" errors="0" skipped="0" time="${_jd}">
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

trap '_jrc=$?; set +e; _junit_emit ${_jrc}; (exit ${_jrc}); _opp_cleanup; exit ${_jrc}' EXIT

echo ">>> PHASE: initialization"

READINESS_TIMEOUT="${READINESS_TIMEOUT:-600}"
READINESS_RETRY_INTERVAL="${READINESS_RETRY_INTERVAL:-30}"
OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

echo ">>> PHASE: Cluster Readiness Check"
: "Start time: $(date '+%F %T')"
: "Timeout: ${READINESS_TIMEOUT}s"

# --- Verify ClusterVersion is Available ---
echo ">>> PHASE: ClusterVersion"
typeset cvAvailable=""
cvAvailable=$(oc get clusterversion version \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}') || true
if [[ "${cvAvailable}" != "True" ]]; then
    echo "ERROR: ClusterVersion not Available (status=${cvAvailable:-unknown})"
    exit 1
fi
: "ClusterVersion Available"

# --- Verify all ClusterOperators are Available ---
echo ">>> PHASE: ClusterOperators"
typeset degradedCOs=""
degradedCOs=$(oc get clusteroperators -o json | jq -r \
    '[.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name] | join(",")') || true
if [[ -n "${degradedCOs}" ]]; then
    echo "WARNING: Degraded ClusterOperators: ${degradedCOs}"
fi

typeset unavailCOs=""
unavailCOs=$(oc get clusteroperators -o json | jq -r \
    '[.items[] | select(.status.conditions[]? | select(.type=="Available" and .status!="True")) | .metadata.name] | join(",")') || true
if [[ -n "${unavailCOs}" ]]; then
    echo "ERROR: Unavailable ClusterOperators: ${unavailCOs}"
    exit 1
fi
: "All ClusterOperators Available"

# --- Verify nodes are Ready ---
echo ">>> PHASE: Node Readiness"
typeset notReadyCount=0
notReadyCount=$(oc get nodes --no-headers | grep -cv ' Ready' || true)
if (( notReadyCount > 0 )); then
    echo "ERROR: ${notReadyCount} node(s) not Ready"
    oc get nodes --no-headers | grep -v ' Ready' || true
    exit 1
fi
: "All nodes Ready"

# --- Verify OPP operators ---
echo ">>> PHASE: OPP Operator Readiness"
typeset -a opListArr=()
IFS=',' read -ra opListArr <<< "${OPP_OPERATORS}"
for op in "${opListArr[@]}"; do
    typeset csvPhase=""
    csvPhase=$(oc get csv -A -o json | jq -r --arg op "${op}" \
        '[.items[] | select(.metadata.name | contains($op))][0].status.phase // "unknown"') || true
    : "Operator ${op}: phase=${csvPhase:-unknown}"
    if [[ "${csvPhase}" != "Succeeded" ]]; then
        echo "WARNING: Operator ${op} not in Succeeded phase (${csvPhase:-unknown})"
    fi
done

echo ">>> PHASE: Readiness Summary"
: "End time: $(date '+%F %T')"
: "Cluster readiness check complete"
true
