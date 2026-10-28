#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit
# bash >= 5.2: '&' in ${var//pat/repl} expands to the match; we need literal
# ampersands in the XML escapes below.
shopt -u patsub_replacement 2>/dev/null || true

# INTEROP-9525 workaround: install the RHACS operator directly via OLM on
# OCP 5.x lanes, where ACM 2.17's governance-policy-addon-controller gates
# OperatorPolicy on openshiftVersion-major == "4" (no Subscription → no
# CSV → no Central CRD → no Central CR). ACM's ConfigurationPolicy, which
# creates Central/SecuredCluster CRs, is NOT gated and works once the
# operator and CRDs exist.
#
# Capture/JUnit contract authority: opp-interop-testing workspace
# docs/design/acs-deploy-evidence.md. Summary:
#   * Single preserved suite/testcase id (acs-deploy /
#     lp-interop--OPP--acs-deploy); classification appears only in the
#     failure type/message attributes.
#   * A default-failing JUnit case is pre-seeded on disk before any work;
#     it is replaced in place at completion (atomic mktemp+mv), so a
#     SIGKILL still leaves a failing case (missing JUnit reads as unknown,
#     never green).
#   * Ordered failure classification (checked in order):
#       1. 3 consecutive poll/query failures -> acs-subscription-query-failed
#       2. precondition: packagemanifest absent (successful query) ->
#          acs-catalog-missing; query error after retries ->
#          acs-catalog-query-failed
#       3. Subscription conditions -> acs-subscription-unsatisfiable /
#          acs-installplan-missing / acs-installplan-failed /
#          acs-catalog-missing
#       4. CSV phase Failed -> acs-csv-failed
#       5. deadline -> acs-csv-timeout
#       default -> acs-unclassified:<type>/<reason> (JUnit error, never pass)
#   * Self-disable: when operatorpolicy-rhacs-operator is Compliant with a
#     matching channel and the CSV is Succeeded, emit
#     workaround_removal_ready=true and exit 0 without installing.
#   * Create-if-absent only: an existing Subscription is adopted (channel
#     mismatch recorded, never overwritten — the OperatorPolicy owns it
#     once ACM 2.17.z carrying stolostron/governance-policy-addon-
#     controller#1397 ships).

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
_opp_cleanup() {
  # Save xtrace log with credentials scrubbed when the step exits non-zero.
  # Takes the recorded exit status explicitly: $? here is unreliable (callers
  # run other commands first).
  local _exit_code="${1:-0}"
  set +x 2>/dev/null
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

# --- Classification state (single writer: _junit_emit) ---
_jn="acs-deploy"
_jsuite="lp-interop--OPP--${_jn}"
_jfile="${ARTIFACT_DIR:-/tmp}/junit_lp-interop--OPP--${_jn}.xml"
_class="acs-unclassified:no-classification"
_class_detail="no classification recorded"
_junit_start=$(date +%s)
_junit_done=0
_props="${ARTIFACT_DIR:-/tmp}/acs-deploy-properties.txt"

# _classify <type> <detail> — record the failure classification (first
# match wins; called in precedence order by the detection code).
_classify() {
  if [[ "${_class}" == "acs-unclassified:no-classification" ]]; then
    _class="${1}"
    _class_detail="${2}"
  fi
}

# _junit_seed — write the default-FAILING case before any work, atomically.
_junit_seed() {
  mkdir -p "$(dirname "${_jfile}")" 2>/dev/null || true
  local _tmp
  _tmp=$(mktemp "$(dirname "${_jfile}")/.junit-XXXXXX")
  cat > "${_tmp}" <<JUNITEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${_jsuite}" tests="1" failures="1" errors="0" skipped="0" time="0">
  <testcase name="${_jn}" classname="lp-interop.OPP.${_jn}" time="0">
    <failure message="step terminated before completion" type="StepTerminated">pre-seeded default failure; the step did not reach a terminal classification</failure>
  </testcase>
</testsuite>
JUNITEOF
  mv -f "${_tmp}" "${_jfile}"
}

# _junit_emit <exit-code> — replace the seeded case IN PLACE (same
# _xml_escape <string> — escape XML special characters for attribute/body
# interpolation (raw oc error output can contain quotes and ampersands).
_xml_escape() {
  local s="$1"
  local _q=\'
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//${_q}/&apos;}"
  printf '%s' "${s}"
}

# testcase id, never appended). tests>=1 always; exit!=0 implies >=1
# failure/error. Atomic write; sha256 and byte count logged.
_junit_emit() {
  (( _junit_done )) && return 0
  _junit_done=1
  local _jr="${1:-0}"
  local _signal="${2:-}"
  local _je
  _je=$(date +%s) || _je=${_junit_start}
  local _jd=$((_je - _junit_start))
  local _fc=0 _ec=0 _fx=""
  local _type _msg _edetail
  if [[ -n "${_signal}" ]]; then
    _type="StepTerminated"
    _msg="step terminated by signal ${_signal} after ${_jd}s"
    _fc=1
    _fx="<failure message=\"${_msg}\" type=\"${_type}\">${_msg}; classification at termination: ${_class}</failure>"
  elif (( _jr != 0 )); then
    _type="${_class}"
    _msg=$(_xml_escape "${_jn} failed: ${_class_detail}")
    _edetail=$(_xml_escape "${_class_detail}")
    if [[ "${_class}" == acs-unclassified:* ]]; then
      _ec=1
      _fx="<error message=\"${_msg}\" type=\"${_type}\">${_edetail}</error>"
    else
      _fc=1
      _fx="<failure message=\"${_msg}\" type=\"${_type}\">${_edetail}</failure>"
    fi
  else
    _fx=""
  fi
  local _tmp
  _tmp=$(mktemp "$(dirname "${_jfile}")/.junit-XXXXXX")
  cat > "${_tmp}" <<JUNITEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${_jsuite}" tests="1" failures="${_fc}" errors="${_ec}" skipped="0" time="${_jd}">
  <testcase name="${_jn}" classname="lp-interop.OPP.${_jn}" time="${_jd}">
    ${_fx}
  </testcase>
</testsuite>
JUNITEOF
  mv -f "${_tmp}" "${_jfile}"
  if [[ -n "${SHARED_DIR:-}" ]]; then
    mkdir -p "${SHARED_DIR}/junit" 2>/dev/null || true
    cp "${_jfile}" "${SHARED_DIR}/junit/" 2>/dev/null || true
  fi
  # Post-condition: tests>=1 and exit!=0 implies >=1 failure/error.
  local _counts
  _counts=$(python3 - "${_jfile}" <<'PYEOF' 2>/dev/null || echo "0 0 0"
import sys, xml.etree.ElementTree as ET
try:
    r = ET.parse(sys.argv[1]).getroot()
    print(r.get("tests", "0"), r.get("failures", "0"), r.get("errors", "0"))
except Exception:
    print("0", "0", "0")
PYEOF
)
  local _t _f _e
  read -r _t _f _e <<<"${_counts}"
  if (( _t < 1 )) || { (( _jr != 0 )) && (( _f + _e < 1 )); }; then
    echo ">>> JUNIT CONTRACT VIOLATION: tests=${_t} failures=${_f} errors=${_e} exit=${_jr}" >&2
    return 1
  fi
  echo ">>> JUNIT: ${_jfile} sha256=$(sha256sum "${_jfile}" | cut -d' ' -f1) bytes=$(wc -c < "${_jfile}") job=${PROW_JOB_ID:-local}"
  return 0
}

# _on_exit <recorded-status> — once-flagged handler; TERM/INT variants pass
# an explicit signal and ignore $?.
_on_exit() {
  local _rc="${1:-0}"
  set +e
  _junit_emit "${_rc}" "${2:-}" || true
  _opp_cleanup "${_rc}"
  exit "${_rc}"
}
trap '_on_exit $? ""' EXIT
trap '_on_exit 143 TERM' TERM
trap '_on_exit 130 INT' INT

_prop() {
  echo "$1=${2:-unknown}" >> "${_props}"
}

# --- Diagnostics: bounded (last 50 events, <=256KiB/object, <=2MiB total) ---
_dump_diagnostics() {
  echo ">>> DIAG: Subscription (OLM, fully-qualified):"
  oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
  echo ">>> DIAG: events in ${ACS_NAMESPACE} (last 50):"
  oc get events -n "${ACS_NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: events in openshift-marketplace (last 50):"
  oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: CSVs in ${ACS_NAMESPACE}:"
  oc get csv -n "${ACS_NAMESPACE}" 2>&1 | head -50 || true
}

echo ">>> PHASE: initialization"

ACS_CHANNEL="${ACS_CHANNEL:-stable}"
ACS_INSTALL_TIMEOUT="${ACS_INSTALL_TIMEOUT:-600}"
ACS_CSV_WAIT_TIMEOUT="${ACS_CSV_WAIT_TIMEOUT:-600}"
ACS_NAMESPACE="${ACS_NAMESPACE:-rhacs-operator}"
ACS_REPORT_ONLY="${ACS_REPORT_ONLY:-0}"

# Input validation: channel name and integer-second timeouts (1..900).
if ! [[ "${ACS_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: invalid ACS_CHANNEL '${ACS_CHANNEL}'"
  _classify "acs-invalid-input" "ACS_CHANNEL failed validation"
  exit 2
fi
for _v in ACS_INSTALL_TIMEOUT ACS_CSV_WAIT_TIMEOUT; do
  if ! [[ "${!_v}" =~ ^[0-9]+$ ]] || (( ${!_v} < 1 || ${!_v} > 900 )); then
    echo "ERROR: ${_v} must be integer seconds in 1..900 (got '${!_v}')"
    _classify "acs-invalid-input" "${_v} failed validation"
    exit 2
  fi
done

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
_junit_seed
: > "${_props}"

# Every oc call gets a request timeout so a hung API call cannot consume
# the step budget.
oc() {
  command oc --request-timeout=20s "$@"
}

echo ">>> PHASE: Deploy ACS Operator (channel: ${ACS_CHANNEL}, csv-name wait: ${ACS_CSV_WAIT_TIMEOUT}s, install wait: ${ACS_INSTALL_TIMEOUT}s)"

if [[ "${ACS_REPORT_ONLY}" == "1" ]]; then
  # Detection, not gating: report object states and exit 0. Runs before the
  # packagemanifest precondition on purpose — detection must work when the
  # catalog is absent or erroring. It also runs before the self-disable
  # check so the full property set is recorded even when an OperatorPolicy
  # owns the install. Subscription presence is queried independently of
  # spec.channel (OLM permits an omitted channel).
  _subname=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null) || _subname=""
  _sub=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _sub=""
  _csvp=$(oc get csv -n "${ACS_NAMESPACE}" -l "operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _csvp=""
  _pm=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o name 2>/dev/null) || _pm=""
  _prop "report_only" "true"
  _prop "acs_subscription" "$([[ -n "${_subname}" ]] && echo adopted || echo absent)"
  _prop "channel_observed" "$([[ -n "${_subname}" ]] && echo "${_sub:-empty}" || echo absent)"
  _prop "csv_phase" "${_csvp:-absent}"
  _prop "packagemanifest" "${_pm:-absent}"
  echo ">>> REPORT_ONLY: subscription=${_sub:-absent} csv=${_csvp:-absent} packagemanifest=$([[ -n "${_pm}" ]] && echo present || echo absent)"
  exit 0
fi

# --- Self-disable: if the OperatorPolicy already owns a healthy install,
#     the workaround is redundant — report and exit 0 without installing.
if oc get crd operatorpolicies.policy.open-cluster-management.io >/dev/null 2>&1; then
  _op_status=$(oc get operatorpolicy -A -o json 2>/dev/null) || _op_status=""
  if [[ -n "${_op_status}" ]]; then
    _self_disable=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    items = d.get("items", [d])
    out = "false"
    for i in items:
        if i.get("metadata", {}).get("name") != "operatorpolicy-rhacs-operator":
            continue
        conds = i.get("status", {}).get("conditions", [])
        compliant = any(c.get("type") == "Compliant" and c.get("status") == "True" for c in conds)
        spec_ch = (i.get("spec", {}).get("subscription", {}) or {}).get("channel")
        out = "true" if compliant and spec_ch else "false"
        break
    print(out)
except Exception:
    print("false")
' "${_op_status}" 2>/dev/null || echo "false")
    if [[ "${_self_disable}" == "true" ]]; then
      _existing_csv=$(oc get csv -n "${ACS_NAMESPACE}" -l "operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _existing_csv=""
      if [[ "${_existing_csv}" == "Succeeded" ]]; then
        echo ">>> workaround_removal_ready=true (OperatorPolicy Compliant, CSV Succeeded) — not installing"
        _prop "workaround_removal_ready" "true"
        _prop "acs_subscription" "adopted"
        exit 0
      fi
    fi
  fi
fi
_prop "workaround_removal_ready" "false"

# --- Fail-fast precondition: packagemanifest must exist and list the
#     requested channel. Three-way classify with bounded retry; a query
#     error is NEVER classified as catalog-missing.
_precondition_ok=false
_pm_raw=""
for _attempt in 1 2 3; do
  if _pm_raw=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>&1); then
    _precondition_ok=true
    break
  fi
  if echo "${_pm_raw}" | grep -qi "not found"; then
    _classify "acs-catalog-missing" "packagemanifest rhacs-operator not found in openshift-marketplace (successful query)"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
  _backoff=$(( _attempt == 1 ? 5 : _attempt == 2 ? 15 : 30 ))
  echo ">>> precondition query failed (attempt ${_attempt}/3), retrying in ${_backoff}s: $(echo "${_pm_raw}" | head -1)"
  sleep "${_backoff}"
done
if [[ "${_precondition_ok}" != "true" ]]; then
  _classify "acs-catalog-query-failed" "packagemanifest query errored after 3 attempts (non-reverting class): $(echo "${_pm_raw}" | head -1)"
  echo "ERROR: ${_class_detail}"
  exit 1
fi
_channel_ok=$(python3 -c '
import json, sys
try:
    ch = sys.argv[1]
    d = json.loads(sys.argv[2])
    names = [c.get("name") for c in d.get("status", {}).get("channels", [])]
    head = next((c.get("currentCSV") for c in d.get("status", {}).get("channels", []) if c.get("name") == ch), None)
    print("ok " + str(head) if ch in names else "absent " + ",".join(names[:8]))
except Exception:
    print("error")
' "${ACS_CHANNEL}" "${_pm_raw}" 2>/dev/null || echo "error")
if [[ "${_channel_ok}" == absent* ]]; then
  _classify "acs-catalog-missing" "channel '${ACS_CHANNEL}' not listed for rhacs-operator (${_channel_ok#absent })"
  echo "ERROR: ${_class_detail}"
  exit 1
fi
if [[ "${_channel_ok}" == "error" ]]; then
  _classify "acs-catalog-query-failed" "packagemanifest channel listing unparseable (query succeeded but returned non-JSON)"
  echo "ERROR: ${_class_detail}"
  exit 1
fi
echo ">>> precondition: rhacs-operator present; channel ${ACS_CHANNEL} head: ${_channel_ok#ok }"



# --- Create-if-absent: namespace ---
if oc get namespace "${ACS_NAMESPACE}" >/dev/null 2>&1; then
  _prop "acs_namespace" "adopted"
else
  if oc create namespace "${ACS_NAMESPACE}" 2>&1; then
    _prop "acs_namespace" "created"
  elif oc get namespace "${ACS_NAMESPACE}" >/dev/null 2>&1; then
    _prop "acs_namespace" "race-tolerated"
  else
    _classify "acs-namespace-error" "failed to create namespace ${ACS_NAMESPACE}"
    exit 1
  fi
fi

# --- Create-if-absent: OperatorGroup (any existing group is adopted; a
# second group in one namespace puts CSVs into TooManyOperatorGroups) ---
if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${ACS_NAMESPACE}" -o name 2>/dev/null)" ]]; then
  _prop "acs_operatorgroup" "adopted"
else
  cat <<EOF | oc apply -f - 2>&1
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: ${ACS_NAMESPACE}
spec: {}
EOF
  _prop "acs_operatorgroup" "created"
fi

# --- Create-if-absent: Subscription (never apply over an existing one) ---
_prop "channel_requested" "${ACS_CHANNEL}"
if oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" >/dev/null 2>&1; then
  _existing_ch=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _existing_ch="unknown"
  _prop "acs_subscription" "adopted"
  _prop "channel_observed" "${_existing_ch}"
  if [[ "${_existing_ch}" != "${ACS_CHANNEL}" ]]; then
    echo ">>> NOTE: existing Subscription channel '${_existing_ch}' != requested '${ACS_CHANNEL}' — adopting, not overwriting (a live OperatorPolicy is the owner)"
    _prop "channel_mismatch" "${_existing_ch}!=${ACS_CHANNEL}"
  fi
else
  # oc create (not apply): if a second writer (a live OperatorPolicy) wins
  # the race, create fails AlreadyExists and we adopt — never overwrite.
  if ! cat <<EOF | oc create -f - 2>&1
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
  then
    if oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" >/dev/null 2>&1; then
      _prop "acs_subscription" "race-tolerated"
      _prop "channel_observed" "$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo unknown)"
      echo ">>> NOTE: Subscription created concurrently by another writer — adopting"
    else
      _classify "acs-subscription-create-error" "failed to create Subscription rhacs-operator"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "acs_subscription" "created"
  fi
fi

# --- Wait for CSV name. Fully-qualified resource type: with ACM
#     installed, bare `oc get subscription` resolves to ACM's CRD and the
#     poll silently reads the wrong API. Query failures are counted; 3
#     consecutive -> acs-subscription-query-failed (before the deadline
#     check, so an error is never classified as a timeout).
echo ">>> PHASE: Waiting for ACS operator CSV (timeout: ${ACS_CSV_WAIT_TIMEOUT}s)"
typeset csvName=""
typeset -i waited=0
typeset -i query_failures=0
while [[ -z "${csvName}" ]] && (( waited < ACS_CSV_WAIT_TIMEOUT )); do
    if csvName=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
        -o jsonpath='{.status.currentCSV}' 2>/dev/null); then
      query_failures=0
    else
      csvName=""
      (( query_failures += 1 )) || true
      if (( query_failures >= 3 )); then
        _classify "acs-subscription-query-failed" "3 consecutive subscription queries failed (rc captured; API/RBAC error, not absence)"
        echo "ERROR: ${_class_detail}"
        _dump_diagnostics
        exit 1
      fi
    fi
    if [[ -z "${csvName}" ]]; then
        # Periodic condition diagnostics every 30s.
        if (( waited > 0 && waited % 30 == 0 )); then
            echo ">>> CSV poll: waited ${waited}/${ACS_CSV_WAIT_TIMEOUT}s — Subscription conditions:"
            oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}  {.type}={.status} reason={.reason} msg={.message}{"\n"}{end}' 2>/dev/null || true
        fi
        sleep 10
        (( waited += 10 )) || true
    fi
done

if [[ -z "${csvName}" ]]; then
    # Classify from Subscription conditions before defaulting to timeout.
    _cond=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {end}' 2>/dev/null) || _cond=""
    case "${_cond}" in
      *CatalogSourcesUnhealthy=True*) _classify "acs-catalog-missing" "Subscription condition CatalogSourcesUnhealthy=True" ;;
      *ConstraintsNotSatisfiable*)    _classify "acs-subscription-unsatisfiable" "Subscription condition ConstraintsNotSatisfiable" ;;
      *InstallPlanMissing*)           _classify "acs-installplan-missing" "Subscription condition InstallPlanMissing" ;;
      *InstallPlanFailed*)            _classify "acs-installplan-failed" "Subscription condition InstallPlanFailed" ;;
      *)                              _classify "acs-csv-timeout" "no currentCSV after ${ACS_CSV_WAIT_TIMEOUT}s (conditions: ${_cond:-none})" ;;
    esac
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
fi

: "CSV: ${csvName}"
_prop "csv_name" "${csvName}"

# --- Wait for CSV Succeeded ---
if ! oc wait csv "${csvName}" -n "${ACS_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout="${ACS_INSTALL_TIMEOUT}s" 2>&1; then
    _phase=$(oc get csv "${csvName}" -n "${ACS_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null) || _phase="unknown"
    if [[ "${_phase}" == "Failed" ]]; then
      _classify "acs-csv-failed" "CSV ${csvName} reached phase Failed"
    else
      _classify "acs-csv-timeout" "CSV ${csvName} not Succeeded after ${ACS_INSTALL_TIMEOUT}s (phase: ${_phase})"
    fi
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
fi

echo ">>> PHASE: ACS operator deployed successfully"
_prop "csv_phase" "Succeeded"
echo ">>> ACS deployment complete (operator only; Central/SecuredCluster CRs are created by ACM ConfigurationPolicy in a later step)"
true
