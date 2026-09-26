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
        echo "<testsuite name=\"opp-post-upgrade-policy\" tests=\"${total}\" failures=\"${failCount}\" skipped=\"${skipCount}\">"
        for i in "${!tcNamesArr[@]}"; do
            typeset name=""
            name="$(XmlEscape "${tcNamesArr[$i]}")"
            echo "  <testcase classname=\"opp-post-upgrade-policy\" name=\"${name}\">"
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
    oc get clusterversion version -o yaml > "${ARTIFACT_DIR}/post-upgrade-clusterversion.yaml" || true
    oc get clusteroperators -o yaml > "${ARTIFACT_DIR}/post-upgrade-clusteroperators.yaml" || true
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
typeset junitFile="${ARTIFACT_DIR}/junit_opp_post_upgrade_policy.xml"

echo ">>> PHASE: Post-Upgrade Policy Check"
: "Start time: $(date '+%F %T')"

# --- Verify ClusterVersion progressing completed ---
echo ">>> PHASE: Upgrade Completion"
typeset cvProgressing=""
cvProgressing=$(oc get clusterversion version \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}') || true
if [[ "${cvProgressing}" == "True" ]]; then
    : "FAIL: ClusterVersion still Progressing"
    AddResult "cv-progressing" "fail" "ClusterVersion still Progressing"
else
    : "PASS: ClusterVersion not Progressing"
    AddResult "cv-progressing" "pass"
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
    : "FAIL: Unhealthy CatalogSources: ${unhealthyCS}"
    AddResult "catalogsource-health" "fail" "Unhealthy CatalogSources: ${unhealthyCS}"
else
    : "PASS: All CatalogSources healthy"
    AddResult "catalogsource-health" "pass"
fi

# --- Verify operator subscriptions ---
echo ">>> PHASE: Subscription Health"
typeset subFailMsg=""
typeset -a opListArr=()
IFS=',' read -ra opListArr <<< "${OPP_OPERATORS}"
for op in "${opListArr[@]}"; do
    typeset csvPhase=""
    csvPhase=$(oc get csv -A -o json | jq -r --arg op "${op}" \
        '[.items[] | select(.metadata.name | contains($op))][0].status.phase // "not-found"') || true
    : "Operator ${op}: phase=${csvPhase}"
    if [[ "${csvPhase}" != "Succeeded" ]]; then
        typeset opMsg="Operator ${op} not Succeeded (phase=${csvPhase})"
        : "FAIL: ${opMsg}"
        if [[ -n "${subFailMsg}" ]]; then subFailMsg="${subFailMsg}; ${opMsg}"; else subFailMsg="${opMsg}"; fi
    fi
done
if [[ -z "${subFailMsg}" ]]; then
    AddResult "operator-subscriptions" "pass"
else
    AddResult "operator-subscriptions" "fail" "${subFailMsg}"
fi

# --- Verify no degraded ClusterOperators ---
echo ">>> PHASE: ClusterOperator Policy"
typeset degradedCOs=""
degradedCOs=$(oc get clusteroperators -o json | jq -r \
    '[.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name] | join(",")') || true
if [[ -n "${degradedCOs}" ]]; then
    : "FAIL: Degraded ClusterOperators: ${degradedCOs}"
    AddResult "clusteroperator-health" "fail" "Degraded ClusterOperators: ${degradedCOs}"
else
    : "PASS: All ClusterOperators healthy"
    AddResult "clusteroperator-health" "pass"
fi

# --- Save policy check results ---
echo ">>> PHASE: Policy Check Report"
typeset -i policyViolations=0
for r in "${tcResultsArr[@]}"; do
    [[ "${r}" == "fail" ]] && (( policyViolations++ )) || true
done

cat > "${ARTIFACT_DIR}/post-upgrade-policy-check.json" <<EOF
{
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "cluster_version": "${clusterVersion:-unknown}",
    "cv_progressing": "${cvProgressing:-unknown}",
    "policy_violations": ${policyViolations}
}
EOF

WriteJunit

echo ">>> PHASE: Policy Check Summary"
: "End time: $(date '+%F %T')"
: "Policy violations: ${policyViolations}"

if (( policyViolations > 0 )); then
    echo "WARNING: ${policyViolations} post-upgrade policy violation(s) detected"
fi

: "Post-upgrade policy check complete"
true
