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

# --- JUnit from cluster-state checks ---
# Accumulators for JUnit generation
typeset -a tcNamesArr=()
typeset -a tcResultsArr=()    # "pass" or "fail"
typeset -a tcMessagesArr=()   # failure message (empty when pass)

AddResult() {
    typeset name="${1:-}"; (($#)) && shift
    typeset result="${1:-}"; (($#)) && shift
    typeset message="${1:-}"; (($#)) && shift
    tcNamesArr+=("${name}")
    tcResultsArr+=("${result}")
    tcMessagesArr+=("${message}")
    true
}

# XmlEscape: Required for bash 5.x where patsub_replacement is enabled
# by default, changing how ${var//pattern/replacement} handles & and \ in
# the replacement string. Without escaping, JUnit XML output is malformed.
XmlEscape() {
    typeset text="${1:-}"; (($#)) && shift
    if shopt -q patsub_replacement 2>/dev/null; then
        shopt -u patsub_replacement
        local _restore_patsub=true
    fi
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&apos;}"
    [[ "${_restore_patsub:-}" == true ]] && shopt -s patsub_replacement
    printf '%s' "${text}"
}

WriteJunit() {
    typeset -i total=${#tcNamesArr[@]}
    typeset -i failCount=0
    typeset -i skipCount=0
    for r in "${tcResultsArr[@]}"; do
        if [[ "${r}" == "fail" ]]; then
            (( failCount++ )) || true
        elif [[ "${r}" == "skip" ]]; then
            (( skipCount++ )) || true
        fi
    done

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"opp-pre-upgrade-checks\" tests=\"${total}\" failures=\"${failCount}\" skipped=\"${skipCount}\">"
        for i in "${!tcNamesArr[@]}"; do
            typeset name=""
            name="$(XmlEscape "${tcNamesArr[$i]}")"
            echo "  <testcase classname=\"opp-pre-upgrade-checks\" name=\"${name}\">"
            if [[ "${tcResultsArr[$i]}" == "fail" ]]; then
                typeset msg=""
                msg="$(XmlEscape "${tcMessagesArr[$i]}")"
                echo "    <failure message=\"${msg}\"></failure>"
            elif [[ "${tcResultsArr[$i]}" == "skip" ]]; then
                typeset msg=""
                msg="$(XmlEscape "${tcMessagesArr[$i]}")"
                echo "    <skipped message=\"${msg}\"/>"
            fi
            echo "  </testcase>"
        done
        echo "</testsuite>"
    } > "${junitFile}"
    : "JUnit XML written to ${junitFile}"
}

# shellcheck disable=SC2317  # invoked via trap
CollectExitArtifacts() {
    : "Collecting exit diagnostics..."
    oc get clusterversion version -o yaml > "${ARTIFACT_DIR}/pre-upgrade-clusterversion.yaml" || true
    oc get clusteroperators -o yaml > "${ARTIFACT_DIR}/pre-upgrade-clusteroperators.yaml" || true
    oc get csv -A -o yaml > "${ARTIFACT_DIR}/pre-upgrade-csvs.yaml" || true
}

# shellcheck disable=SC2317
_propagate_junit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}

trap '_opp_cleanup; CollectExitArtifacts; _propagate_junit' EXIT

echo ">>> PHASE: initialization"

OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
typeset junitFile="${ARTIFACT_DIR}/junit_opp_pre_upgrade_checks.xml"

echo ">>> PHASE: Pre-Upgrade Checks"
: "Start time: $(date '+%F %T')"

# --- Record current cluster state ---
echo ">>> PHASE: Cluster State Snapshot"
typeset clusterVersion=""
clusterVersion=$(oc get clusterversion version -o jsonpath='{.status.desired.version}') || true
: "Current cluster version: ${clusterVersion:-unknown}"

# --- Verify MCP stability ---
echo ">>> PHASE: MachineConfigPool Stability"
typeset mcpFailMsg=""
typeset updatingMCPs=""
updatingMCPs=$(oc get machineconfigpools -o json | jq -r \
    '[.items[] | select(.status.conditions[]? | select(.type=="Updating" and .status=="True")) | .metadata.name] | join(",")') || true
if [[ -n "${updatingMCPs}" ]]; then
    mcpFailMsg="MCPs still updating: ${updatingMCPs}"
    : "FAIL: ${mcpFailMsg}"
fi

typeset degradedMCPs=""
degradedMCPs=$(oc get machineconfigpools -o json | jq -r \
    '[.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name] | join(",")') || true
if [[ -n "${degradedMCPs}" ]]; then
    typeset degradeMsg="Degraded MCPs: ${degradedMCPs}"
    : "FAIL: ${degradeMsg}"
    if [[ -n "${mcpFailMsg}" ]]; then mcpFailMsg="${mcpFailMsg}; ${degradeMsg}"; else mcpFailMsg="${degradeMsg}"; fi
fi

if [[ -z "${mcpFailMsg}" ]]; then
    AddResult "mcp-stability" "pass"
else
    AddResult "mcp-stability" "fail" "${mcpFailMsg}"
fi

# --- Verify operator health ---
echo ">>> PHASE: Operator Health"
typeset opFailMsg=""
typeset -a opListArr=()
IFS=',' read -ra opListArr <<< "${OPP_OPERATORS}"
for op in "${opListArr[@]}"; do
    typeset csvPhase=""
    csvPhase=$(oc get csv -A -o json | jq -r --arg op "${op}" \
        '[.items[] | select(.metadata.name | contains($op))][0].status.phase // "not-found"') || true
    : "Operator ${op}: phase=${csvPhase}"
    if [[ "${csvPhase}" != "Succeeded" ]]; then
        typeset opMsg="Operator ${op} not healthy (phase=${csvPhase})"
        : "FAIL: ${opMsg}"
        if [[ -n "${opFailMsg}" ]]; then opFailMsg="${opFailMsg}; ${opMsg}"; else opFailMsg="${opMsg}"; fi
    fi
done
if [[ -z "${opFailMsg}" ]]; then
    AddResult "operator-health" "pass"
else
    AddResult "operator-health" "fail" "${opFailMsg}"
fi

# --- Save pre-upgrade state ---
echo ">>> PHASE: Saving Pre-Upgrade State"
typeset -i checksFailed=0
for r in "${tcResultsArr[@]}"; do
    [[ "${r}" == "fail" ]] && (( checksFailed++ )) || true
done

cat > "${ARTIFACT_DIR}/pre-upgrade-checks.json" <<EOF
{
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "cluster_version": "${clusterVersion:-unknown}",
    "checks_failed": ${checksFailed}
}
EOF

WriteJunit

echo ">>> PHASE: Pre-Upgrade Summary"
: "End time: $(date '+%F %T')"
: "Checks failed: ${checksFailed}"

if (( checksFailed > 0 )); then
    echo "WARNING: ${checksFailed} pre-upgrade check(s) failed (continuing)"
fi

: "Pre-upgrade checks complete"
true
