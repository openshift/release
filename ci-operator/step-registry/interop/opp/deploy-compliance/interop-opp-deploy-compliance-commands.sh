#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit
# bash >= 5.2: '&' in ${var//pat/repl} expands to the match; we need literal
# ampersands in the XML escapes below.
shopt -u patsub_replacement 2>/dev/null || true

# INTEROP-9710 workaround: install the compliance-operator directly via OLM on
# OCP 5.x lanes, where ACM 2.17's governance-policy-addon-controller gates
# OperatorPolicy on openshiftVersion-major == "4" (no Subscription -> no CSV ->
# no ScanSettingBinding/ComplianceSuite CRDs). Replicates
# policy-compliance-operator-install.yaml object-for-object (namespace
# openshift-compliance, OperatorGroup compliance-operator with
# targetNamespaces [openshift-compliance], Subscription compliance-operator on
# channel stable). No post-install CRs: the policy creates none, and the OPP
# bundle's compliance consumption is driven by ACM policy, not by this step.
#
# Capture/JUnit contract (same shape as interop-opp-deploy-acs, authority
# opp-interop-testing docs/design/acs-deploy-evidence.md):
#   * Single preserved suite/testcase id (compliance-deploy /
#     lp-interop--OPP--compliance-deploy); classification appears only in the
#     failure type/message attributes.
#   * A default-failing JUnit case is pre-seeded on disk before any work and
#     replaced in place at completion (atomic mktemp+mv), so a SIGKILL still
#     leaves a failing case (missing JUnit reads as unknown, never green).
#   * Self-disable: when operatorpolicy-comp-operator is Compliant with a
#     matching channel AND the CSV is Succeeded, emit
#     workaround_removal_ready=true and exit 0.
#   * Create-if-absent only: an existing object is adopted, never overwritten
#     (the OperatorPolicy owns it once ACM 2.17.z carrying
#     stolostron/governance-policy-addon-controller#1397 ships).

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
# Once-flagged like _junit_emit: a TERM/INT trap runs _on_exit -> exit, which
# fires the EXIT trap -> _on_exit again; without this guard the redaction/copy
# below (and its TRACE line) would run twice.
_cleanup_done=0
_opp_cleanup() {
  # Save xtrace log with credentials scrubbed when the step exits non-zero.
  # Takes the recorded exit status explicitly: $? here is unreliable (callers
  # run other commands first).
  local _exit_code="${1:-0}"
  if (( _cleanup_done )); then return 0; fi
  _cleanup_done=1
  set +x 2>/dev/null
  # Scrub credentials before copying (admin tokens/passwords never reach the
  # log by design; this is the backstop).
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

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
if [[ -f "${SHARED_DIR:-/nonexistent}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

# Every oc call gets a request timeout so a hung API call cannot consume the
# step budget.
oc() {
  command oc --request-timeout=20s "$@"
}

# --- Classification state (single writer: _junit_emit) ---
_jn="compliance-deploy"
_jsuite="lp-interop--OPP--${_jn}"
_jfile="${ARTIFACT_DIR}/junit_lp-interop--OPP--${_jn}.xml"
_class="compliance-unclassified:no-classification"
_class_detail="no classification recorded"
_junit_start=$(date +%s)
_junit_done=0
_props="${ARTIFACT_DIR}/compliance-deploy-properties.txt"

# --- Shared work deadline (single wall-clock authority) ---
# The step ref.yaml timeout minus its grace_period is the work budget. Setup,
# precondition, every wait, classification, and diagnostics all charge against
# this ONE deadline, so a slow setup or an oc request that straddles a poll
# deadline cannot push classification/JUnit past the budget (and so cannot
# leave TERM to record StepTerminated in place of a real class).
# Reserves subtracted from the deadline when capping a phase:
#   _diag_reserve        bounded diagnostics (4 x 20s request-timeout) + JUnit
#   _oc_overrun_reserve  one in-flight 20s oc request at a phase deadline
_work_budget=1650
_diag_reserve=120
_oc_overrun_reserve=25
_work_deadline=$(( _junit_start + _work_budget ))

# _classify <type> <detail>: record the failure classification (first match
# wins; called in precedence order by the detection code).
_classify() {
  if [[ "${_class}" == "compliance-unclassified:no-classification" ]]; then
    _class="${1}"
    _class_detail="${2}"
  fi
}

# _prop <key> <value>: append one provenance property.
_prop() {
  echo "$1=${2:-unknown}" >> "${_props}"
}

# _clamp_deadline <epoch>: cap a phase deadline at the shared work deadline
# minus the diagnostics and one-in-flight-request reserves. An oc request
# started just before the returned deadline (<=20s) therefore finishes before
# _work_deadline - _diag_reserve, leaving that reserve for classification,
# diagnostics, and JUnit. Prints the (possibly lowered) deadline.
_clamp_deadline() {
  local _cap=$(( _work_deadline - _diag_reserve - _oc_overrun_reserve ))
  if (( $1 > _cap )); then printf '%s' "${_cap}"; else printf '%s' "$1"; fi
}

# _xml_escape <string>: escape XML special characters for attribute/body
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

# _junit_seed: write the default-FAILING case before any work, atomically.
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

# _junit_emit <exit-code> [signal]: replace the seeded case IN PLACE (same
# testcase id, never appended). tests>=1 always; exit!=0 implies >=1
# failure/error. Atomic write; sha256 and byte count logged.
_junit_emit() {
  if (( _junit_done )); then return 0; fi
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
    if [[ "${_class}" == compliance-unclassified:* ]]; then
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

# _on_exit <recorded-status> [signal]: once-flagged handler; TERM/INT variants
# pass an explicit signal and ignore $?.
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

# _poll_jsonpath <resource> <name> <namespace> <jsonpath> <want> [fail-value]
#                 [label]
# Polls one jsonpath value until it equals <want> ("@any" accepts any
# non-empty value; "@contains:<substr>" accepts any value containing <substr>). Uses the caller-set global _poll_deadline (absolute epoch).
# Sets _poll_last to the last observed value. Returns:
#   0 matched | 1 deadline | 2 three consecutive query failures
#   3 observed the <fail-value> terminal state
# An object that does not exist yet ("not found") is absence, not an API
# error: it is waited out and never classified as a query failure.
_po_poll_interval=10
_poll_jsonpath() {
  local _res=$1 _name=$2 _ns=$3 _jp=$4 _want=$5
  local _failval="${6:-}" _label="${7:-poll}"
  local _out="" _fails=0 _left=0 _n=0
  local -a _nsa=()
  if [[ -n "${_ns}" ]]; then _nsa=(-n "${_ns}"); fi
  _poll_last=""
  while :; do
    if _out=$(oc get "${_res}" "${_name}" ${_nsa[@]+"${_nsa[@]}"} -o jsonpath="${_jp}" 2>&1); then
      _fails=0
      _poll_last="${_out}"
      if [[ "${_want}" == "@any" ]]; then
        if [[ -n "${_out}" ]]; then return 0; fi
      elif [[ "${_want}" == @contains:* ]]; then
        if [[ "${_out}" == *"${_want#@contains:}"* ]]; then return 0; fi
      elif [[ "${_out}" == "${_want}" ]]; then
        return 0
      fi
      if [[ -n "${_failval}" && "${_out}" == "${_failval}" ]]; then return 3; fi
    else
      _poll_last=""
      if printf '%s' "${_out}" | grep -qiE 'not ?found'; then
        : # object absent yet: wait, do not count as a query failure
      else
        (( _fails += 1 )) || true
        if (( _fails >= 3 )); then
          echo ">>> ${_label}: 3 consecutive queries failed (last: $(printf '%s' "${_out}" | head -1))" >&2
          return 2
        fi
      fi
    fi
    _left=$(( _poll_deadline - $(date +%s) ))
    if (( _left <= 0 )); then return 1; fi
    (( _n += 1 )) || true
    if (( _n % 3 == 0 )); then
      echo ">>> ${_label} poll: ${_left}s left, observed '${_poll_last:-absent}'"
    fi
    if (( _left < _po_poll_interval )); then sleep "${_left}"; else sleep "${_po_poll_interval}"; fi
  done
}

# --- Pre-seed the default-failing JUnit case and the property file ---
_junit_seed
: > "${_props}"
# --- Environment (every value env-overridable) ---
COMPLIANCE_OPERATOR_CHANNEL="${COMPLIANCE_OPERATOR_CHANNEL:-stable}"
COMPLIANCE_NAMESPACE="${COMPLIANCE_NAMESPACE:-openshift-compliance}"
COMPLIANCE_CSV_WAIT_TIMEOUT="${COMPLIANCE_CSV_WAIT_TIMEOUT:-600}"
COMPLIANCE_INSTALL_TIMEOUT="${COMPLIANCE_INSTALL_TIMEOUT:-600}"
COMPLIANCE_REPORT_ONLY="${COMPLIANCE_REPORT_ONLY:-0}"

if ! [[ "${COMPLIANCE_OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: invalid COMPLIANCE_OPERATOR_CHANNEL '${COMPLIANCE_OPERATOR_CHANNEL}'"
  _classify "compliance-invalid-input" "COMPLIANCE_OPERATOR_CHANNEL failed validation"
  exit 2
fi
for _v in COMPLIANCE_CSV_WAIT_TIMEOUT COMPLIANCE_INSTALL_TIMEOUT; do
  _v_raw="${!_v}"
  # Bounded to 9 digits so the 10# conversion below cannot wrap a 64-bit
  # integer into the accepted range.
  if ! [[ "${_v_raw}" =~ ^[0-9]{1,9}$ ]]; then
    echo "ERROR: ${_v} must be integer seconds in 1..900 (got '${_v_raw}')"
    _classify "compliance-invalid-input" "${_v} failed validation"
    exit 2
  fi
  # Normalize to decimal before any arithmetic sees it: bash reads a
  # leading-zero literal as OCTAL ("0600" is 384s) and "0900" aborts the
  # script outright.
  printf -v "${_v}" '%d' "$(( 10#${_v_raw} ))"
  if (( ${!_v} < 1 || ${!_v} > 900 )); then
    echo "ERROR: ${_v} must be integer seconds in 1..900 (got '${_v_raw}')"
    _classify "compliance-invalid-input" "${_v} failed validation"
    exit 2
  fi
done

# Budget invariant (ref.yaml: timeout 30m = 1800s, grace_period 150s => 1650s
# work; overhead 180s + precondition <=120s + diagnostics <=120s => phase
# budget 1230s). Same inequality as interop-opp-deploy-acs: the two waits are
# sequential and each independently bounded, so the SUM must multiply out.
# Fail-fast half (exit 2); the runtime half is _work_deadline, which charges
# elapsed setup and caps every phase deadline.
_phase_sum=$(( COMPLIANCE_CSV_WAIT_TIMEOUT + COMPLIANCE_INSTALL_TIMEOUT ))
if (( _phase_sum > 1230 )); then
  echo "ERROR: COMPLIANCE_CSV_WAIT_TIMEOUT + COMPLIANCE_INSTALL_TIMEOUT must be <= 1230s (work budget 1650s - overhead 180s - precondition 120s - diagnostics 120s); got ${_phase_sum}s"
  _classify "compliance-invalid-input" "wait sum ${_phase_sum}s exceeds the step work budget"
  exit 2
fi

echo ">>> PHASE: deploy compliance-operator (channel: ${COMPLIANCE_OPERATOR_CHANNEL}, namespace: ${COMPLIANCE_NAMESPACE}, CSV name wait: ${COMPLIANCE_CSV_WAIT_TIMEOUT}s, CSV wait: ${COMPLIANCE_INSTALL_TIMEOUT}s)"

# --- Diagnostics: bounded (last 50 events, <=256KiB/object) ---
_dump_diagnostics() {
  echo ">>> DIAG: Subscription (OLM, fully-qualified):"
  oc get subscription.operators.coreos.com compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
  echo ">>> DIAG: events in ${COMPLIANCE_NAMESPACE} (last 50):"
  oc get events -n "${COMPLIANCE_NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: events in openshift-marketplace (last 50):"
  oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: CSVs in ${COMPLIANCE_NAMESPACE}:"
  oc get csv -n "${COMPLIANCE_NAMESPACE}" 2>&1 | head -50 || true
}

if [[ "${COMPLIANCE_REPORT_ONLY}" == "1" ]]; then
  # Detection, not gating: report object states and exit 0. Runs before the
  # packagemanifest precondition on purpose (detection must work when the
  # catalog is absent or erroring) and before the self-disable check so the
  # full property set is recorded even when an OperatorPolicy owns the install.
  _sub=$(oc get subscription.operators.coreos.com compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _sub=""
  _csvp=$(oc get csv -n "${COMPLIANCE_NAMESPACE}" -l "operators.coreos.com/compliance-operator.${COMPLIANCE_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _csvp=""
  _pm=$(oc get packagemanifest compliance-operator -n openshift-marketplace -o name 2>/dev/null) || _pm=""
  _prop "report_only" "true"
  _prop "channel_observed" "${_sub:-absent}"
  _prop "csv_phase" "${_csvp:-absent}"
  _prop "packagemanifest" "$([[ -n "${_pm}" ]] && echo present || echo absent)"
  echo ">>> REPORT_ONLY: channel=${_sub:-absent} csv=${_csvp:-absent} packagemanifest=$([[ -n "${_pm}" ]] && echo present || echo absent)"
  exit 0
fi

# --- Self-disable predicate ---
# operatorpolicy-comp-operator Compliant AND subscription channel matches AND
# CSV Succeeded. No post-install CRs, so no further term.
# Queried cluster-wide by name (ACM installs the OperatorPolicy in the managed
# cluster namespace, local-cluster) and the observed namespace is recorded.
_prop "channel_requested" "${COMPLIANCE_OPERATOR_CHANNEL}"
if oc get crd operatorpolicies.policy.open-cluster-management.io >/dev/null 2>&1; then
  _op_status=$(oc get operatorpolicies.policy.open-cluster-management.io -A -o json 2>/dev/null) || _op_status=""
  if [[ -n "${_op_status}" ]]; then
    _sd_out=$(printf '%s' "${_op_status}" | python3 -c '
import json, sys
name, requested = sys.argv[1], sys.argv[2]
try:
    d = json.load(sys.stdin)
    items = d.get("items", [d])
    for i in items:
        if i.get("metadata", {}).get("name") != name:
            continue
        conds = i.get("status", {}).get("conditions", [])
        compliant = any(c.get("type") == "Compliant" and c.get("status") == "True" for c in conds)
        spec_ch = ((i.get("spec", {}).get("subscription") or {}).get("channel") or "")
        ns = i.get("metadata", {}).get("namespace") or ""
        # A policy that omits the channel constrains nothing: the channel term
        # of the predicate is vacuously satisfied and is recorded as "-".
        if compliant and (spec_ch == "" or spec_ch == requested):
            print("true " + ns + " " + (spec_ch or "-"))
        else:
            print("false " + ns + " " + (spec_ch or "-"))
        break
    else:
        print("absent - -")
except Exception:
    print("absent - -")
' operatorpolicy-comp-operator "${COMPLIANCE_OPERATOR_CHANNEL}" 2>/dev/null) || _sd_out="absent - -"
    _sd_ok="absent" _sd_ns="-" _sd_ch="-"
    read -r _sd_ok _sd_ns _sd_ch <<<"${_sd_out}" || true
    _prop "operatorpolicy_namespace" "${_sd_ns:-unknown}"
    _prop "operatorpolicy_channel" "${_sd_ch:-unknown}"
    if [[ "${_sd_ok}" == "true" ]]; then
      _existing_csv=$(oc get csv -n "${COMPLIANCE_NAMESPACE}" -l "operators.coreos.com/compliance-operator.${COMPLIANCE_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _existing_csv=""
      if [[ "${_existing_csv}" == "Succeeded" ]]; then
        echo ">>> workaround_removal_ready=true (OperatorPolicy Compliant, channel ${_sd_ch}, CSV Succeeded) - not installing"
        _prop "workaround_removal_ready" "true"
        _prop "compliance_subscription" "adopted"
        _prop "csv_phase" "Succeeded"
        exit 0
      fi
    elif [[ "${_sd_ch}" != "-" && "${_sd_ch}" != "${COMPLIANCE_OPERATOR_CHANNEL}" ]]; then
      echo ">>> NOTE: OperatorPolicy channel '${_sd_ch}' != requested '${COMPLIANCE_OPERATOR_CHANNEL}': self-disable withheld, installing"
      _prop "channel_self_disable_withheld" "${_sd_ch}!=${COMPLIANCE_OPERATOR_CHANNEL}"
    fi
  fi
fi

# Exactly one workaround_removal_ready line is emitted per run: the true
# branch exits above, so a run that reaches this point is installing.
_prop "workaround_removal_ready" "false"

# --- Fail-fast precondition: packagemanifest must exist and list the
#     requested channel. Three-way classify with bounded retry; a query error
#     is NEVER classified as catalog-missing. ---
_precondition_ok=false
_pm_raw=""
for _attempt in 1 2 3; do
  if _pm_raw=$(oc get packagemanifest compliance-operator -n openshift-marketplace -o json 2>&1); then
    _precondition_ok=true
    break
  fi
  if printf '%s' "${_pm_raw}" | grep -qi "not found"; then
    _classify "compliance-catalog-missing" "packagemanifest compliance-operator not found in openshift-marketplace (successful query)"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
  _backoff=$(( _attempt == 1 ? 5 : _attempt == 2 ? 15 : 30 ))
  echo ">>> precondition query failed (attempt ${_attempt}/3), retrying in ${_backoff}s: $(printf '%s' "${_pm_raw}" | head -1)"
  sleep "${_backoff}"
done
if [[ "${_precondition_ok}" != "true" ]]; then
  _classify "compliance-catalog-query-failed" "packagemanifest query errored after 3 attempts (non-reverting class): $(printf '%s' "${_pm_raw}" | head -1)"
  echo "ERROR: ${_class_detail}"
  exit 1
fi
_channel_ok=$(printf '%s' "${_pm_raw}" | python3 -c '
import json, sys
try:
    ch = sys.argv[1]
    d = json.load(sys.stdin)
    chans = d.get("status", {}).get("channels", [])
    names = [c.get("name") for c in chans if c.get("name")]
    head = next((c.get("currentCSV") for c in chans if c.get("name") == ch), None)
    print("ok " + str(head) if ch in names else "absent " + ",".join(names[:8]))
except Exception:
    print("error")
' "${COMPLIANCE_OPERATOR_CHANNEL}" 2>/dev/null) || _channel_ok="error"
case "${_channel_ok}" in
  absent*)
    _classify "compliance-catalog-missing" "channel '${COMPLIANCE_OPERATOR_CHANNEL}' not listed for compliance-operator (${_channel_ok#absent })"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
  error)
    _classify "compliance-catalog-query-failed" "packagemanifest channel listing unparseable (query succeeded but returned non-JSON)"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
esac
echo ">>> precondition: compliance-operator present; channel ${COMPLIANCE_OPERATOR_CHANNEL} head: ${_channel_ok#ok }"

# --- Create-if-absent: namespace (policy-compliance-operator-install.yaml) ---
if oc get namespace "${COMPLIANCE_NAMESPACE}" >/dev/null 2>&1; then
  _prop "compliance_namespace" "adopted"
else
  if oc create namespace "${COMPLIANCE_NAMESPACE}" 2>&1; then
    _prop "compliance_namespace" "created"
  elif oc get namespace "${COMPLIANCE_NAMESPACE}" >/dev/null 2>&1; then
    _prop "compliance_namespace" "race-tolerated"
  else
    _classify "compliance-namespace-error" "failed to create namespace ${COMPLIANCE_NAMESPACE}"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
fi

# --- Create-if-absent: OperatorGroup (name compliance-operator,
#     targetNamespaces [openshift-compliance]; any existing group is adopted;
#     a second group in one namespace puts CSVs into TooManyOperatorGroups).
#     oc create, not apply: if a second writer (a live OperatorPolicy) wins the
#     race, create fails AlreadyExists and we adopt; never overwrite the
#     existing spec.targetNamespaces. ---
if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${COMPLIANCE_NAMESPACE}" -o name 2>/dev/null)" ]]; then
  _prop "compliance_operatorgroup" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: compliance-operator
  namespace: ${COMPLIANCE_NAMESPACE}
spec:
  targetNamespaces:
    - ${COMPLIANCE_NAMESPACE}
EOF
  then
    if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${COMPLIANCE_NAMESPACE}" -o name 2>/dev/null)" ]]; then
      _prop "compliance_operatorgroup" "race-tolerated"
      echo ">>> NOTE: OperatorGroup created concurrently by another writer - adopting"
    else
      _classify "compliance-operatorgroup-create-error" "failed to create OperatorGroup compliance-operator in ${COMPLIANCE_NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "compliance_operatorgroup" "created"
  fi
fi

# --- Create-if-absent: Subscription (oc create, not apply: if a second writer
#     (a live OperatorPolicy) wins the race, create fails AlreadyExists and
#     we adopt; never overwrite) ---
if oc get subscription.operators.coreos.com compliance-operator -n "${COMPLIANCE_NAMESPACE}" >/dev/null 2>&1; then
  _existing_ch=$(oc get subscription.operators.coreos.com compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _existing_ch="unknown"
  _prop "compliance_subscription" "adopted"
  _prop "channel_observed" "${_existing_ch:-empty}"
  if [[ -n "${_existing_ch}" && "${_existing_ch}" != "${COMPLIANCE_OPERATOR_CHANNEL}" ]]; then
    echo ">>> NOTE: existing Subscription channel '${_existing_ch}' != requested '${COMPLIANCE_OPERATOR_CHANNEL}' - adopting, not overwriting (a live OperatorPolicy is the owner)"
    _prop "channel_mismatch" "${_existing_ch}!=${COMPLIANCE_OPERATOR_CHANNEL}"
  fi
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: compliance-operator
  namespace: ${COMPLIANCE_NAMESPACE}
spec:
  channel: "${COMPLIANCE_OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: compliance-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  then
    if oc get subscription.operators.coreos.com compliance-operator -n "${COMPLIANCE_NAMESPACE}" >/dev/null 2>&1; then
      _prop "compliance_subscription" "race-tolerated"
      _prop "channel_observed" "$(oc get subscription.operators.coreos.com compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo unknown)"
      echo ">>> NOTE: Subscription created concurrently by another writer - adopting"
    else
      _classify "compliance-subscription-create-error" "failed to create Subscription compliance-operator"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "compliance_subscription" "created"
    _prop "channel_observed" "${COMPLIANCE_OPERATOR_CHANNEL}"
  fi
fi

# --- Wait for the CSV name (read status.currentCSV; the patch version is
#     never hardcoded). Elapsed-time deadline, so a slow-but-successful
#     response is charged against the budget. ---
echo ">>> PHASE: waiting for the compliance-operator CSV name (timeout: ${COMPLIANCE_CSV_WAIT_TIMEOUT}s)"
_csv_want=$(( $(date +%s) + COMPLIANCE_CSV_WAIT_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_csv_want}")
if (( _poll_deadline < _csv_want )); then
  echo ">>> NOTE: CSV-name wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${COMPLIANCE_CSV_WAIT_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath subscription.operators.coreos.com compliance-operator "${COMPLIANCE_NAMESPACE}" '{.status.currentCSV}' '@any' '' "compliance-operator currentCSV"; then
  csvName="${_poll_last}"
  _prop "csv_name" "${csvName}"
else
  _prc=$?
  _cond=$(oc get subscription.operators.coreos.com compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {end}' 2>/dev/null) || _cond=""
  if (( _prc == 2 )); then
    _classify "compliance-subscription-query-failed" "3 consecutive subscription queries failed (rc captured; API/RBAC error, not absence)"
  else
    case "${_cond}" in
      *CatalogSourcesUnhealthy=True*) _classify "compliance-catalog-missing" "Subscription condition CatalogSourcesUnhealthy=True" ;;
      *ConstraintsNotSatisfiable*)    _classify "compliance-subscription-unsatisfiable" "Subscription condition ConstraintsNotSatisfiable" ;;
      *InstallPlanMissing*)           _classify "compliance-installplan-missing" "Subscription condition InstallPlanMissing" ;;
      *InstallPlanFailed*)            _classify "compliance-installplan-failed" "Subscription condition InstallPlanFailed" ;;
      *)                              _classify "compliance-csv-timeout" "no currentCSV after ${COMPLIANCE_CSV_WAIT_TIMEOUT}s (conditions: ${_cond:-none})" ;;
    esac
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> compliance-operator CSV: ${csvName}"

# --- Wait for CSV Succeeded (a not-yet-created CSV object is waited out, not
#     classified as an API failure). ---
echo ">>> PHASE: waiting for CSV ${csvName} Succeeded (timeout: ${COMPLIANCE_INSTALL_TIMEOUT}s)"
_install_want=$(( $(date +%s) + COMPLIANCE_INSTALL_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_install_want}")
if (( _poll_deadline < _install_want )); then
  echo ">>> NOTE: CSV-Succeeded wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${COMPLIANCE_INSTALL_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath clusterserviceversions.operators.coreos.com "${csvName}" "${COMPLIANCE_NAMESPACE}" '{.status.phase}' Succeeded Failed "CSV ${csvName} phase"; then
  _prop "csv_phase" "Succeeded"
else
  _prc=$?
  if (( _prc == 3 )); then
    _classify "compliance-csv-failed" "CSV ${csvName} reached phase Failed"
  elif (( _prc == 2 )); then
    _classify "compliance-subscription-query-failed" "3 consecutive CSV queries for ${csvName} failed (API/RBAC error, not absence)"
  else
    _classify "compliance-csv-timeout" "CSV ${csvName} not Succeeded after ${COMPLIANCE_INSTALL_TIMEOUT}s (phase: ${_poll_last:-unknown})"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi

_prop "compliance_deployed" "true"
echo ">>> PHASE: compliance-operator deployed (CSV Succeeded; the policy creates no CRs, so this step creates none)"
true
