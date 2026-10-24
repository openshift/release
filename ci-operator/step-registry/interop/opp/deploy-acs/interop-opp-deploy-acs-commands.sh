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
  # Emit a JUnit XML result for the ACS deploy step and propagate to SHARED_DIR/junit.
  (( _junit_emitted )) && return 0
  _junit_emitted=1
  local _jr=${1:-0}
  local _je
  _je=$(date +%s) || _je=${_junit_start}
  local _jd=$((_je - _junit_start))
  local _jn="acs-deploy"
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

trap '_jrc=$?; set +e; _junit_emit ${_jrc}; _opp_cleanup; exit ${_jrc}' EXIT

echo ">>> PHASE: initialization"

ACS_CHANNEL="${ACS_CHANNEL:-stable}"
ACS_INSTALL_TIMEOUT="${ACS_INSTALL_TIMEOUT:-15m}"
ACS_NAMESPACE="${ACS_NAMESPACE:-rhacs-operator}"
ACS_CENTRAL_NAMESPACE="${ACS_CENTRAL_NAMESPACE:-stackrox}"

# Convert duration (e.g. 15m, 900s, 1h) to seconds
duration_to_seconds() {
    local val="${1}"
    case "${val}" in
        *h) echo $(( ${val%h} * 3600 )) ;;
        *m) echo $(( ${val%m} * 60 )) ;;
        *s) echo $(( ${val%s} )) ;;
        *)  echo "${val}" ;;  # assume seconds if no unit
    esac
}

CSV_TIMEOUT_SECONDS=$(duration_to_seconds "${ACS_INSTALL_TIMEOUT}")

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

echo ">>> PHASE: Pre-check CatalogSource readiness"
: "Checking redhat-operators CatalogSource in openshift-marketplace"
cs_ready=""
typeset -i cs_waited=0
while [[ -z "${cs_ready}" ]] && (( cs_waited < 120 )); do
    cs_state=$(oc get catalogsource redhat-operators -n openshift-marketplace \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null) || true
    if [[ "${cs_state}" == "READY" ]]; then
        cs_ready="true"
        echo ">>> CatalogSource redhat-operators is READY"
    else
        echo ">>> CatalogSource redhat-operators state: ${cs_state:-unknown} (waited ${cs_waited}s)"
        sleep 10
        (( cs_waited += 10 ))
    fi
done
if [[ -z "${cs_ready}" ]]; then
    echo "WARNING: CatalogSource redhat-operators not READY after ${cs_waited}s, proceeding anyway"
    oc get catalogsource redhat-operators -n openshift-marketplace -o yaml 2>&1 || true
fi

echo ">>> PHASE: Deploy ACS Operator"
: "Channel: ${ACS_CHANNEL}"
: "Timeout: ${ACS_INSTALL_TIMEOUT} (${CSV_TIMEOUT_SECONDS}s)"

# --- Create namespace ---
oc create namespace "${ACS_NAMESPACE}" --dry-run=client -o yaml | oc apply -f - 2>&1

# --- Create OperatorGroup ---
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: ${ACS_NAMESPACE}
spec: {}
EOF

# --- Create Subscription ---
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhacs-operator
  namespace: ${ACS_NAMESPACE}
spec:
  channel: "${ACS_CHANNEL}"
  installPlanApproval: Automatic
  name: rhacs-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# --- Wait for CSV ---
echo ">>> PHASE: Waiting for ACS operator CSV (timeout: ${CSV_TIMEOUT_SECONDS}s)"
typeset csvName=""
typeset -i waited=0
while [[ -z "${csvName}" ]] && (( waited < CSV_TIMEOUT_SECONDS )); do
    csvName=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
        -o jsonpath='{.status.currentCSV}' 2>/dev/null) || true
    if [[ -z "${csvName}" ]]; then
        # Print diagnostics every 30s to help debug stalls
        if (( waited > 0 && waited % 30 == 0 )); then
            echo ">>> CSV poll: waited ${waited}/${CSV_TIMEOUT_SECONDS}s — checking Subscription conditions:"
            oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}  {.type}={.status} reason={.reason} msg={.message}{"\n"}{end}' 2>/dev/null || true
        fi
        sleep 10
        (( waited += 10 ))
    fi
done

if [[ -z "${csvName}" ]]; then
    echo "ERROR: Timed out after ${CSV_TIMEOUT_SECONDS}s waiting for ACS operator CSV"
    echo ">>> Dumping Subscription YAML for diagnostics:"
    oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o yaml 2>&1 || true
    echo ">>> Dumping events in ${ACS_NAMESPACE} namespace:"
    oc get events -n "${ACS_NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 || true
    echo ">>> Dumping events in openshift-marketplace namespace:"
    oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>&1 || true
    exit 1
fi

: "CSV: ${csvName}"
oc wait csv "${csvName}" -n "${ACS_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout="${ACS_INSTALL_TIMEOUT}" 2>&1

echo ">>> PHASE: ACS operator deployed successfully"
: "ACS deployment complete"
true
