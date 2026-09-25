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
  local _jn="post-upgrade-policy"
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

OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

echo ">>> PHASE: Post-Upgrade Policy Check"
: "Start time: $(date '+%F %T')"

typeset -i policyViolations=0

# --- Verify ClusterVersion progressing completed ---
echo ">>> PHASE: Upgrade Completion"
typeset cvProgressing=""
cvProgressing=$(oc get clusterversion version \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}') || true
if [[ "${cvProgressing}" == "True" ]]; then
    echo "WARNING: ClusterVersion still Progressing"
    (( policyViolations += 1 ))
fi

typeset clusterVersion=""
clusterVersion=$(oc get clusterversion version -o jsonpath='{.status.desired.version}') || true
: "Cluster version: ${clusterVersion:-unknown}"

# --- Verify operator catalog sources ---
echo ">>> PHASE: CatalogSource Health"
typeset unhealthyCS=""
unhealthyCS=$(oc get catalogsource -n openshift-marketplace -o json | jq -r \
    '[.items[] | select(.status.connectionState.lastObservedState != "READY") | .metadata.name] | join(",")') || true
if [[ -n "${unhealthyCS}" ]]; then
    echo "WARNING: Unhealthy CatalogSources: ${unhealthyCS}"
    (( policyViolations += 1 ))
fi

# --- Verify operator subscriptions ---
echo ">>> PHASE: Subscription Health"
typeset -a opListArr=()
IFS=',' read -ra opListArr <<< "${OPP_OPERATORS}"
for op in "${opListArr[@]}"; do
    typeset csvPhase=""
    csvPhase=$(oc get csv -A -o json | jq -r --arg op "${op}" \
        '[.items[] | select(.metadata.name | contains($op))][0].status.phase // "not-found"') || true
    : "Operator ${op}: phase=${csvPhase}"
    if [[ "${csvPhase}" != "Succeeded" ]]; then
        echo "WARNING: Operator ${op} policy violation: not Succeeded (phase=${csvPhase})"
        (( policyViolations += 1 ))
    fi
done

# --- Verify no degraded ClusterOperators ---
echo ">>> PHASE: ClusterOperator Policy"
typeset degradedCOs=""
degradedCOs=$(oc get clusteroperators -o json | jq -r \
    '[.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name] | join(",")') || true
if [[ -n "${degradedCOs}" ]]; then
    echo "WARNING: Degraded ClusterOperators: ${degradedCOs}"
    (( policyViolations += 1 ))
fi

# --- Save policy check results ---
echo ">>> PHASE: Policy Check Report"
cat > "${ARTIFACT_DIR}/post-upgrade-policy-check.json" <<EOF
{
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "cluster_version": "${clusterVersion:-unknown}",
    "cv_progressing": "${cvProgressing:-unknown}",
    "policy_violations": ${policyViolations}
}
EOF

oc get clusterversion version -o yaml > "${ARTIFACT_DIR}/post-upgrade-clusterversion.yaml" 2>&1 || true
oc get clusteroperators -o yaml > "${ARTIFACT_DIR}/post-upgrade-clusteroperators.yaml" 2>&1 || true

echo ">>> PHASE: Policy Check Summary"
: "End time: $(date '+%F %T')"
: "Policy violations: ${policyViolations}"

if (( policyViolations > 0 )); then
    echo "WARNING: ${policyViolations} post-upgrade policy violation(s) detected"
fi

: "Post-upgrade policy check complete"
true
