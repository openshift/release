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
  # Save xtrace log with credentials scrubbed when the step exits non-zero.
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
  # Emit a JUnit XML result for the readiness step and propagate to SHARED_DIR/junit.
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

if ! [[ "${READINESS_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: READINESS_TIMEOUT must be a non-negative integer"
    exit 1
fi
if ! [[ "${READINESS_RETRY_INTERVAL}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: READINESS_RETRY_INTERVAL must be a positive integer"
    exit 1
fi

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

echo ">>> PHASE: Cluster Readiness Check"
: "Start time: $(date '+%F %T')"
: "Timeout: ${READINESS_TIMEOUT}s"

typeset -i readinessStart readinessDeadline
readinessStart=$(date +%s)
readinessDeadline=$((readinessStart + READINESS_TIMEOUT))

function WaitForReadiness() {
    # Retry a check function until it passes or READINESS_TIMEOUT is exceeded.
    typeset description="${1}" checkFunction="${2}"
    typeset -i attempt=1 checkResult=0 now=0 sleepSeconds=0

    while true; do
        checkResult=0
        "${checkFunction}" || checkResult=$?
        if (( checkResult == 0 )); then
            : "${description} ready after ${attempt} attempt(s)"
            return 0
        fi
        # A result other than one is a query or parsing error, not a readiness
        # state that can safely be retried.
        if (( checkResult != 1 )); then
            return "${checkResult}"
        fi

        now=$(date +%s)
        if (( now >= readinessDeadline )); then
            echo "ERROR: ${description} did not become ready within ${READINESS_TIMEOUT}s"
            return 1
        fi

        sleepSeconds=${READINESS_RETRY_INTERVAL}
        if (( now + sleepSeconds > readinessDeadline )); then
            sleepSeconds=$((readinessDeadline - now))
        fi
        echo "${description} not ready (attempt ${attempt}); retrying in ${sleepSeconds}s"
        sleep "${sleepSeconds}"
        (( attempt += 1 ))
    done
}

function CheckClusterVersion() {
    # Verify the ClusterVersion resource reports Available=True.
    typeset cvAvailable=""
    if ! cvAvailable=$(oc get clusterversion version \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'); then
        echo "ERROR: Failed to query ClusterVersion"
        return 2
    fi
    if [[ "${cvAvailable}" != "True" ]]; then
        echo "ClusterVersion not Available (status=${cvAvailable:-unknown})"
        return 1
    fi
    : "ClusterVersion Available"
}

function CheckClusterOperators() {
    # Verify no ClusterOperators are Degraded or unavailable.
    typeset coOutput="" degradedCOs="" unavailCOs=""
    coOutput=$(mktemp)
    if ! oc get clusteroperators -o json > "${coOutput}"; then
        rm -f "${coOutput}"
        echo "ERROR: Failed to query ClusterOperators"
        return 2
    fi
    if ! degradedCOs=$(jq -r \
        '[.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name] | join(",")' \
        "${coOutput}"); then
        rm -f "${coOutput}"
        echo "ERROR: Failed to parse ClusterOperator status"
        return 2
    fi
    if ! unavailCOs=$(jq -r \
        '[.items[] | select(.status.conditions[]? | select(.type=="Available" and .status!="True")) | .metadata.name] | join(",")' \
        "${coOutput}"); then
        rm -f "${coOutput}"
        echo "ERROR: Failed to parse ClusterOperator status"
        return 2
    fi
    rm -f "${coOutput}"

    if [[ -n "${degradedCOs}" ]]; then
        echo "WARNING: Degraded ClusterOperators: ${degradedCOs}"
    fi
    if [[ -n "${unavailCOs}" ]]; then
        echo "Unavailable ClusterOperators: ${unavailCOs}"
        return 1
    fi
    : "All ClusterOperators Available"
}

function CheckNodes() {
    # Count nodes by Ready condition status without exposing node names in logs.
    typeset nodeStatuses="" nodeStatusSummary=""
    typeset -i notReadyCount=0

    # Query only Ready condition values so node names never enter the logs or
    # failure xtrace. Treat a failed query as fatal before counting statuses.
    if ! nodeStatuses=$(oc get nodes -o go-template='{{range .items}}{{$ready := "Unknown"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$ready = .status}}{{end}}{{end}}{{$ready}}{{"\n"}}{{end}}'); then
        echo "ERROR: Failed to query node readiness"
        return 2
    fi
    notReadyCount=$(printf '%s\n' "${nodeStatuses}" | awk 'NF && $1 != "True" { count++ } END { print count + 0 }')
    nodeStatusSummary=$(printf '%s\n' "${nodeStatuses}" | awk '
        NF { count[$1]++ }
        END {
            printf "Ready=True:%d, Ready=False:%d, Ready=Unknown:%d", \
                count["True"] + 0, count["False"] + 0, count["Unknown"] + 0
        }')
    if (( notReadyCount > 0 )); then
        echo "${notReadyCount} node(s) not Ready (${nodeStatusSummary})"
        return 1
    fi
    : "All nodes Ready (${nodeStatusSummary})"
}

# --- Verify ClusterVersion is Available ---
echo ">>> PHASE: ClusterVersion"
if ! WaitForReadiness "ClusterVersion" CheckClusterVersion; then
    exit 1
fi

# --- Verify all ClusterOperators are Available ---
echo ">>> PHASE: ClusterOperators"
if ! WaitForReadiness "ClusterOperators" CheckClusterOperators; then
    exit 1
fi

# --- Verify nodes are Ready ---
echo ">>> PHASE: Node Readiness"
if ! WaitForReadiness "Nodes" CheckNodes; then
    exit 1
fi

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
