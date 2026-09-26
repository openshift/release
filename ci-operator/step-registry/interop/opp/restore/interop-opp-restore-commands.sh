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
        echo "<testsuite name=\"opp-restore\" tests=\"${total}\" failures=\"${failCount}\" skipped=\"${skipCount}\">"
        for i in "${!tcNamesArr[@]}"; do
            typeset name=""
            name="$(XmlEscape "${tcNamesArr[$i]}")"
            echo "  <testcase classname=\"opp-restore\" name=\"${name}\">"
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
    oc get clusterversion version -o yaml > "${ARTIFACT_DIR}/restore-clusterversion.yaml" || true
    oc get clusteroperators -o yaml > "${ARTIFACT_DIR}/restore-clusteroperators.yaml" || true
    oc get nodes -o yaml > "${ARTIFACT_DIR}/restore-nodes.yaml" || true
}

# shellcheck disable=SC2317
_propagate_junit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}

trap '_opp_cleanup; CollectExitArtifacts; _propagate_junit' EXIT

echo ">>> PHASE: initialization"

RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-600}"
OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
typeset junitFile="${ARTIFACT_DIR}/junit_opp_restore.xml"

echo ">>> PHASE: Post-Upgrade Cluster Restore Validation"
: "Start time: $(date '+%F %T')"
: "Restore timeout: ${RESTORE_TIMEOUT}s"

# --- Verify cluster health after upgrade ---
echo ">>> PHASE: Cluster Version Check"
typeset clusterVersion=""
clusterVersion=$(oc get clusterversion version -o jsonpath='{.status.desired.version}') || true
: "Cluster version: ${clusterVersion:-unknown}"

typeset cvAvailable=""
cvAvailable=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}') || true
if [[ "${cvAvailable}" != "True" ]]; then
    : "FAIL: ClusterVersion not Available (status=${cvAvailable:-unknown})"
    AddResult "clusterversion-available" "fail" "ClusterVersion not Available (status=${cvAvailable:-unknown})"
else
    : "PASS: ClusterVersion Available"
    AddResult "clusterversion-available" "pass"
fi

# --- Verify operator state ---
echo ">>> PHASE: Operator State Verification"
typeset opFailMsg=""
typeset -a opListArr=()
IFS=',' read -ra opListArr <<< "${OPP_OPERATORS}"
for op in "${opListArr[@]}"; do
    typeset csvPhase=""
    csvPhase=$(oc get csv -A -o json | jq -r --arg op "${op}" \
        '[.items[] | select(.metadata.name | contains($op))][0].status.phase // "unknown"') || true
    : "Operator ${op}: phase=${csvPhase:-unknown}"
    if [[ "${csvPhase}" != "Succeeded" ]]; then
        typeset opMsg="Operator ${op} not in Succeeded phase (phase=${csvPhase:-unknown})"
        : "FAIL: ${opMsg}"
        if [[ -n "${opFailMsg}" ]]; then opFailMsg="${opFailMsg}; ${opMsg}"; else opFailMsg="${opMsg}"; fi
    fi
done
if [[ -z "${opFailMsg}" ]]; then
    AddResult "operator-state" "pass"
else
    AddResult "operator-state" "fail" "${opFailMsg}"
fi

# --- Verify node health ---
echo ">>> PHASE: Node Health Check"
typeset notReadyNodes=""
notReadyNodes=$(oc get nodes --no-headers | grep -v ' Ready' | wc -l) || true
if (( notReadyNodes > 0 )); then
    : "FAIL: ${notReadyNodes} node(s) not in Ready state"
    AddResult "node-health" "fail" "${notReadyNodes} node(s) not in Ready state"
else
    : "PASS: All nodes Ready"
    AddResult "node-health" "pass"
fi

# --- Save restore validation report ---
echo ">>> PHASE: Restore Summary"
typeset -i opErrors=0
for r in "${tcResultsArr[@]}"; do
    [[ "${r}" == "fail" ]] && (( opErrors++ )) || true
done

cat > "${ARTIFACT_DIR}/restore-validation.json" <<EOF
{
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "cluster_version": "${clusterVersion:-unknown}",
    "cv_available": "${cvAvailable:-unknown}",
    "check_failures": ${opErrors},
    "not_ready_nodes": ${notReadyNodes:-0}
}
EOF

WriteJunit

: "End time: $(date '+%F %T')"
: "Post-upgrade restore validation complete"
true
