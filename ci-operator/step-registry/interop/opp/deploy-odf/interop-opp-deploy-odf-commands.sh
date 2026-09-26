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
  # Emit a JUnit XML result for the ODF deploy step and propagate to SHARED_DIR/junit.
  (( _junit_emitted )) && return 0
  _junit_emitted=1
  local _jr=${1:-0}
  local _je
  _je=$(date +%s) || _je=${_junit_start}
  local _jd=$((_je - _junit_start))
  local _jn="odf-deploy"
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

ODF_CHANNEL="${ODF_CHANNEL:-stable-4.17}"
ODF_INSTALL_TIMEOUT="${ODF_INSTALL_TIMEOUT:-15m}"
ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

echo ">>> PHASE: Deploy ODF Operator"
: "Channel: ${ODF_CHANNEL}"
: "Timeout: ${ODF_INSTALL_TIMEOUT}"

# --- Create namespace ---
oc create namespace "${ODF_NAMESPACE}" --dry-run=client -o yaml | oc apply -f - 2>&1

# --- Create OperatorGroup ---
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: ${ODF_NAMESPACE}
spec:
  targetNamespaces:
    - ${ODF_NAMESPACE}
EOF

# --- Create Subscription ---
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: ${ODF_NAMESPACE}
spec:
  channel: "${ODF_CHANNEL}"
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# --- Wait for CSV ---
echo ">>> PHASE: Waiting for ODF operator CSV"
typeset csvName=""
typeset -i waited=0
while [[ -z "${csvName}" ]] && (( waited < 300 )); do
    csvName=$(oc get subscription odf-operator -n "${ODF_NAMESPACE}" \
        -o jsonpath='{.status.currentCSV}' 2>/dev/null) || true
    if [[ -z "${csvName}" ]]; then
        sleep 10
        (( waited += 10 ))
    fi
done

if [[ -z "${csvName}" ]]; then
    echo "ERROR: Timed out waiting for ODF operator CSV"
    exit 1
fi

: "CSV: ${csvName}"
oc wait csv "${csvName}" -n "${ODF_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout="${ODF_INSTALL_TIMEOUT}" 2>&1

echo ">>> PHASE: ODF operator deployed successfully"
: "ODF deployment complete"
true
