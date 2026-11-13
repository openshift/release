#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit
# bash >= 5.2: '&' in ${var//pat/repl} expands to the match; we need literal
# ampersands in the XML escapes below.
shopt -u patsub_replacement 2>/dev/null || true

# INTEROP-9710 workaround: install the Quay (quay-operator) operator plus its
# QuayRegistry directly via OLM on OCP 5.x lanes, where ACM 2.17's
# governance-policy-addon-controller gates OperatorPolicy on
# openshiftVersion-major == "4" (no Subscription -> no CSV -> no QuayRegistry
# CRD -> no registry, no admin secrets). Replicates policy-install-quay.yaml
# and policy-config-quay.yaml object-for-object, so the downstream steps
# (interop-opp-odf-health, interop-tests-opp-quay-smoke) find identical
# objects: namespace/OperatorGroup/Subscription local-quay|quay-operator,
# Secret init-config-bundle-secret, QuayRegistry registry, RBAC+Job
# create-admin-user, and the resulting quayadmin / quaydevel /
# quay-pull-secret secrets.
#
# Capture/JUnit contract (same shape as interop-opp-deploy-acs, authority
# opp-interop-testing docs/design/acs-deploy-evidence.md):
#   * Single preserved suite/testcase id (quay-deploy /
#     lp-interop--OPP--quay-deploy); classification appears only in the
#     failure type/message attributes.
#   * A default-failing JUnit case is pre-seeded on disk before any work and
#     replaced in place at completion (atomic mktemp+mv), so a SIGKILL still
#     leaves a failing case (missing JUnit reads as unknown, never green).
#   * Self-disable: when operatorpolicy-quay-operator is Compliant with a
#     matching channel, the CSV is Succeeded AND the existing QuayRegistry is
#     Available, emit workaround_removal_ready=true and exit 0.
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
_jn="quay-deploy"
_jsuite="lp-interop--OPP--${_jn}"
_jfile="${ARTIFACT_DIR}/junit_lp-interop--OPP--${_jn}.xml"
_class="quay-unclassified:no-classification"
_class_detail="no classification recorded"
_junit_start=$(date +%s)
_junit_done=0
_props="${ARTIFACT_DIR}/quay-deploy-properties.txt"

# --- Shared work deadline (single wall-clock authority) ---
# The step ref.yaml timeout minus its grace_period is the work budget. Setup,
# precondition, every wait, classification, and diagnostics all charge against
# this ONE deadline, so a slow setup or an oc request that straddles a poll
# deadline cannot push classification/JUnit past the budget (and so cannot
# leave TERM to record StepTerminated in place of a real class).
# Reserves subtracted from the deadline when capping a phase:
#   _diag_reserve        bounded diagnostics (4 x 20s request-timeout) + JUnit
#   _oc_overrun_reserve  one in-flight 20s oc request at a phase deadline
_work_budget=2550
_diag_reserve=120
_oc_overrun_reserve=25
_work_deadline=$(( _junit_start + _work_budget ))

# _classify <type> <detail>: record the failure classification (first match
# wins; called in precedence order by the detection code).
_classify() {
  if [[ "${_class}" == "quay-unclassified:no-classification" ]]; then
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
    if [[ "${_class}" == quay-unclassified:* ]]; then
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
QUAY_OPERATOR_CHANNEL="${QUAY_OPERATOR_CHANNEL:-stable-3.17}"
QUAY_NAMESPACE="${QUAY_NAMESPACE:-local-quay}"
QUAY_CSV_WAIT_TIMEOUT="${QUAY_CSV_WAIT_TIMEOUT:-300}"
QUAY_INSTALL_TIMEOUT="${QUAY_INSTALL_TIMEOUT:-600}"
QUAY_REGISTRY_TIMEOUT="${QUAY_REGISTRY_TIMEOUT:-600}"
QUAY_ADMIN_JOB_TIMEOUT="${QUAY_ADMIN_JOB_TIMEOUT:-420}"
QUAY_REPORT_ONLY="${QUAY_REPORT_ONLY:-0}"

# Input validation: channel name and integer-second timeouts.
if ! [[ "${QUAY_OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: invalid QUAY_OPERATOR_CHANNEL '${QUAY_OPERATOR_CHANNEL}'"
  _classify "quay-invalid-input" "QUAY_OPERATOR_CHANNEL failed validation"
  exit 2
fi
for _v in QUAY_CSV_WAIT_TIMEOUT QUAY_INSTALL_TIMEOUT QUAY_REGISTRY_TIMEOUT QUAY_ADMIN_JOB_TIMEOUT; do
  _v_raw="${!_v}"
  # Bounded to 9 digits so the 10# conversion below cannot wrap a 64-bit
  # integer into the accepted range.
  if ! [[ "${_v_raw}" =~ ^[0-9]{1,9}$ ]]; then
    echo "ERROR: ${_v} must be integer seconds in 1..1800 (got '${_v_raw}')"
    _classify "quay-invalid-input" "${_v} failed validation"
    exit 2
  fi
  # Normalize to decimal before any arithmetic sees it: bash reads a
  # leading-zero literal as OCTAL ("0600" is 384s) and "0900" aborts the
  # script outright, so an un-normalized value would clear the range check at
  # the wrong magnitude and hand a wrong number to every deadline and log line.
  printf -v "${_v}" '%d' "$(( 10#${_v_raw} ))"
  if (( ${!_v} < 1 || ${!_v} > 1800 )); then
    echo "ERROR: ${_v} must be integer seconds in 1..1800 (got '${_v_raw}')"
    _classify "quay-invalid-input" "${_v} failed validation"
    exit 2
  fi
done

# The ported create-admin-user Job (policy-config-quay.yaml) hardcodes
# local-quay in its oc calls, so the namespace is validated rather than
# silently honored: a non-default value would create the RBAC/Job in one
# namespace while the Job acts on another.
if [[ "${QUAY_NAMESPACE}" != "local-quay" ]]; then
  echo "ERROR: QUAY_NAMESPACE must be local-quay (got '${QUAY_NAMESPACE}'); the ported create-admin-user Job hardcodes it"
  _classify "quay-invalid-input" "QUAY_NAMESPACE '${QUAY_NAMESPACE}' != local-quay (step and ported Job must act on one namespace)"
  exit 2
fi

# Budget invariant (ref.yaml: timeout 45m = 2700s, grace_period 150s => 2550s
# work; overhead 180s + precondition <=120s + diagnostics <=120s => phase
# budget 2130s). The four waits are sequential and each independently bounded,
# so the SUM must multiply out: per-variable 1..1800 alone admits 4 x 1800s
# and would let TERM record StepTerminated instead of a real classification.
# This is the fail-fast half (reject absurd configs, exit 2); the runtime half
# is _work_deadline above, which charges elapsed setup and caps every phase
# deadline so the arithmetic holds regardless of setup slowness.
_phase_sum=$(( QUAY_CSV_WAIT_TIMEOUT + QUAY_INSTALL_TIMEOUT + QUAY_REGISTRY_TIMEOUT + QUAY_ADMIN_JOB_TIMEOUT ))
if (( _phase_sum > 2130 )); then
  echo "ERROR: phase waits sum to ${_phase_sum}s, must be <= 2130s (work budget 2550s - overhead 180s - precondition 120s - diagnostics 120s)"
  _classify "quay-invalid-input" "phase wait sum ${_phase_sum}s exceeds the step work budget"
  exit 2
fi

echo ">>> PHASE: deploy Quay (channel: ${QUAY_OPERATOR_CHANNEL}, namespace: ${QUAY_NAMESPACE}, CSV name wait: ${QUAY_CSV_WAIT_TIMEOUT}s, CSV wait: ${QUAY_INSTALL_TIMEOUT}s, registry wait: ${QUAY_REGISTRY_TIMEOUT}s, admin job wait: ${QUAY_ADMIN_JOB_TIMEOUT}s)"

# --- Diagnostics: bounded (last 50 events, <=256KiB/object) ---
_dump_diagnostics() {
  echo ">>> DIAG: Subscription (OLM, fully-qualified):"
  oc get subscription.operators.coreos.com quay-operator -n "${QUAY_NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
  echo ">>> DIAG: events in ${QUAY_NAMESPACE} (last 50):"
  oc get events -n "${QUAY_NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: events in openshift-marketplace (last 50):"
  oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: CSVs in ${QUAY_NAMESPACE}:"
  oc get csv -n "${QUAY_NAMESPACE}" 2>&1 | head -50 || true
  echo ">>> DIAG: QuayRegistry registry status:"
  oc get quayregistries.quay.redhat.com registry -n "${QUAY_NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
}

if [[ "${QUAY_REPORT_ONLY}" == "1" ]]; then
  # Detection, not gating: report object states and exit 0. Runs before the
  # packagemanifest precondition on purpose (detection must work when the
  # catalog is absent or erroring) and before the self-disable check so the
  # full property set is recorded even when an OperatorPolicy owns the install.
  _sub=$(oc get subscription.operators.coreos.com quay-operator -n "${QUAY_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _sub=""
  _csvp=$(oc get csv -n "${QUAY_NAMESPACE}" -l "operators.coreos.com/quay-operator.${QUAY_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _csvp=""
  _qr=$(oc get quayregistries.quay.redhat.com registry -n "${QUAY_NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null) || _qr=""
  _pm=$(oc get packagemanifest quay-operator -n openshift-marketplace -o name 2>/dev/null) || _pm=""
  _prop "report_only" "true"
  _prop "channel_observed" "${_sub:-absent}"
  _prop "csv_phase" "${_csvp:-absent}"
  _prop "quay_registry_conditions" "${_qr:-absent}"
  _prop "packagemanifest" "$([[ -n "${_pm}" ]] && echo present || echo absent)"
  echo ">>> REPORT_ONLY: channel=${_sub:-absent} csv=${_csvp:-absent} packagemanifest=$([[ -n "${_pm}" ]] && echo present || echo absent)"
  exit 0
fi

# --- Self-disable predicate ---
# operatorpolicy-quay-operator Compliant AND subscription channel matches AND
# CSV Succeeded AND QuayRegistry registry in local-quay Available=true.
# Queried cluster-wide by name (ACM installs the OperatorPolicy in the managed
# cluster namespace, local-cluster) and the observed namespace is recorded; an
# absent/NonCompliant policy is simply "no second writer yet".
_prop "channel_requested" "${QUAY_OPERATOR_CHANNEL}"
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
' operatorpolicy-quay-operator "${QUAY_OPERATOR_CHANNEL}" 2>/dev/null) || _sd_out="absent - -"
    _sd_ok="absent" _sd_ns="-" _sd_ch="-"
    read -r _sd_ok _sd_ns _sd_ch <<<"${_sd_out}" || true
    _prop "operatorpolicy_namespace" "${_sd_ns:-unknown}"
    _prop "operatorpolicy_channel" "${_sd_ch:-unknown}"
    if [[ "${_sd_ok}" == "true" ]]; then
      _existing_csv=$(oc get csv -n "${QUAY_NAMESPACE}" -l "operators.coreos.com/quay-operator.${QUAY_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _existing_csv=""
      if [[ "${_existing_csv}" == "Succeeded" ]]; then
        _qr_avail=$(oc get quayregistries.quay.redhat.com registry -n "${QUAY_NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null) || _qr_avail=""
        if printf '%s' "${_qr_avail}" | grep -qx 'Available=True'; then
          echo ">>> workaround_removal_ready=true (OperatorPolicy Compliant, channel ${_sd_ch}, CSV Succeeded, QuayRegistry Available) - not installing"
          _prop "workaround_removal_ready" "true"
          _prop "quay_subscription" "adopted"
          _prop "csv_phase" "Succeeded"
          _prop "quay_registry_available" "True"
          exit 0
        fi
        echo ">>> NOTE: OperatorPolicy Compliant and CSV Succeeded but QuayRegistry is not Available yet - installing"
      fi
    elif [[ "${_sd_ch}" != "-" && "${_sd_ch}" != "${QUAY_OPERATOR_CHANNEL}" ]]; then
      echo ">>> NOTE: OperatorPolicy channel '${_sd_ch}' != requested '${QUAY_OPERATOR_CHANNEL}': self-disable withheld, installing"
      _prop "channel_self_disable_withheld" "${_sd_ch}!=${QUAY_OPERATOR_CHANNEL}"
    fi
  fi
fi

# Exactly one workaround_removal_ready line is emitted per run: the true
# branch exits above, so a run that reaches this point is installing.
_prop "workaround_removal_ready" "false"

# --- Fail-fast precondition: packagemanifest must exist and list the
#     requested channel. Three-way classify with bounded retry; a query error
#     is NEVER classified as catalog-missing.
_precondition_ok=false
_pm_raw=""
for _attempt in 1 2 3; do
  if _pm_raw=$(oc get packagemanifest quay-operator -n openshift-marketplace -o json 2>&1); then
    _precondition_ok=true
    break
  fi
  if printf '%s' "${_pm_raw}" | grep -qi "not found"; then
    _classify "quay-catalog-missing" "packagemanifest quay-operator not found in openshift-marketplace (successful query)"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
  _backoff=$(( _attempt == 1 ? 5 : _attempt == 2 ? 15 : 30 ))
  echo ">>> precondition query failed (attempt ${_attempt}/3), retrying in ${_backoff}s: $(printf '%s' "${_pm_raw}" | head -1)"
  sleep "${_backoff}"
done
if [[ "${_precondition_ok}" != "true" ]]; then
  _classify "quay-catalog-query-failed" "packagemanifest query errored after 3 attempts (non-reverting class): $(printf '%s' "${_pm_raw}" | head -1)"
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
' "${QUAY_OPERATOR_CHANNEL}" 2>/dev/null) || _channel_ok="error"
case "${_channel_ok}" in
  absent*)
    _classify "quay-catalog-missing" "channel '${QUAY_OPERATOR_CHANNEL}' not listed for quay-operator (${_channel_ok#absent })"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
  error)
    _classify "quay-catalog-query-failed" "packagemanifest channel listing unparseable (query succeeded but returned non-JSON)"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
esac
echo ">>> precondition: quay-operator present; channel ${QUAY_OPERATOR_CHANNEL} head: ${_channel_ok#ok }"

# --- Create-if-absent: namespace (policy-install-quay.yaml carries the
#     cluster-monitoring label; ensured idempotently) ---
if oc get namespace "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
  _prop "quay_namespace" "adopted"
else
  if oc create namespace "${QUAY_NAMESPACE}" 2>&1; then
    _prop "quay_namespace" "created"
  elif oc get namespace "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
    _prop "quay_namespace" "race-tolerated"
  else
    _classify "quay-namespace-error" "failed to create namespace ${QUAY_NAMESPACE}"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
fi
oc label namespace "${QUAY_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite >/dev/null 2>&1 || true

# --- Create-if-absent: OperatorGroup (name local-quay, targetNamespaces
#     [local-quay]; any existing group is adopted; a second group in one
#     namespace puts CSVs into TooManyOperatorGroups). oc create, not apply: if
#     a second writer (a live OperatorPolicy) wins the race, create fails
#     AlreadyExists and we adopt; never overwrite spec.targetNamespaces. ---
if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${QUAY_NAMESPACE}" -o name 2>/dev/null)" ]]; then
  _prop "quay_operatorgroup" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${QUAY_NAMESPACE}
  namespace: ${QUAY_NAMESPACE}
spec:
  targetNamespaces:
    - ${QUAY_NAMESPACE}
EOF
  then
    if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${QUAY_NAMESPACE}" -o name 2>/dev/null)" ]]; then
      _prop "quay_operatorgroup" "race-tolerated"
      echo ">>> NOTE: OperatorGroup created concurrently by another writer - adopting"
    else
      _classify "quay-operatorgroup-create-error" "failed to create OperatorGroup ${QUAY_NAMESPACE} in ${QUAY_NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "quay_operatorgroup" "created"
  fi
fi

# --- Create-if-absent: Subscription (oc create, not apply: if a second writer
#     (a live OperatorPolicy) wins the race, create fails AlreadyExists and
#     we adopt; never overwrite) ---
if oc get subscription.operators.coreos.com quay-operator -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
  _existing_ch=$(oc get subscription.operators.coreos.com quay-operator -n "${QUAY_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _existing_ch="unknown"
  _prop "quay_subscription" "adopted"
  _prop "channel_observed" "${_existing_ch}"
  if [[ "${_existing_ch}" != "${QUAY_OPERATOR_CHANNEL}" ]]; then
    echo ">>> NOTE: existing Subscription channel '${_existing_ch}' != requested '${QUAY_OPERATOR_CHANNEL}' - adopting, not overwriting (a live OperatorPolicy is the owner)"
    _prop "channel_mismatch" "${_existing_ch}!=${QUAY_OPERATOR_CHANNEL}"
  fi
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: ${QUAY_NAMESPACE}
  labels:
    operators.coreos.com/quay-operator.${QUAY_NAMESPACE}: ""
spec:
  channel: "${QUAY_OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: quay-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  then
    if oc get subscription.operators.coreos.com quay-operator -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
      _prop "quay_subscription" "race-tolerated"
      _prop "channel_observed" "$(oc get subscription.operators.coreos.com quay-operator -n "${QUAY_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo unknown)"
      echo ">>> NOTE: Subscription created concurrently by another writer - adopting"
    else
      _classify "quay-subscription-create-error" "failed to create Subscription quay-operator"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "quay_subscription" "created"
    _prop "channel_observed" "${QUAY_OPERATOR_CHANNEL}"
  fi
fi

# --- Wait for the CSV name (read status.currentCSV; the patch version is
#     never hardcoded). Elapsed-time deadline, so a slow-but-successful
#     response is charged against the budget. ---
echo ">>> PHASE: waiting for the quay-operator CSV name (timeout: ${QUAY_CSV_WAIT_TIMEOUT}s)"
_csv_want=$(( $(date +%s) + QUAY_CSV_WAIT_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_csv_want}")
if (( _poll_deadline < _csv_want )); then
  echo ">>> NOTE: CSV-name wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${QUAY_CSV_WAIT_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath subscription.operators.coreos.com quay-operator "${QUAY_NAMESPACE}" '{.status.currentCSV}' '@any' '' "quay-operator currentCSV"; then
  csvName="${_poll_last}"
  _prop "csv_name" "${csvName}"
else
  _prc=$?
  _cond=$(oc get subscription.operators.coreos.com quay-operator -n "${QUAY_NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {end}' 2>/dev/null) || _cond=""
  if (( _prc == 2 )); then
    _classify "quay-subscription-query-failed" "3 consecutive subscription queries failed (rc captured; API/RBAC error, not absence)"
  else
    case "${_cond}" in
      *CatalogSourcesUnhealthy=True*) _classify "quay-catalog-missing" "Subscription condition CatalogSourcesUnhealthy=True" ;;
      *ConstraintsNotSatisfiable*)    _classify "quay-subscription-unsatisfiable" "Subscription condition ConstraintsNotSatisfiable" ;;
      *InstallPlanMissing*)           _classify "quay-installplan-missing" "Subscription condition InstallPlanMissing" ;;
      *InstallPlanFailed*)            _classify "quay-installplan-failed" "Subscription condition InstallPlanFailed" ;;
      *)                              _classify "quay-csv-timeout" "no currentCSV after ${QUAY_CSV_WAIT_TIMEOUT}s (conditions: ${_cond:-none})" ;;
    esac
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> quay-operator CSV: ${csvName}"

# --- Wait for CSV Succeeded (a not-yet-created CSV object is waited out, not
#     classified as an API failure). ---
echo ">>> PHASE: waiting for CSV ${csvName} Succeeded (timeout: ${QUAY_INSTALL_TIMEOUT}s)"
_install_want=$(( $(date +%s) + QUAY_INSTALL_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_install_want}")
if (( _poll_deadline < _install_want )); then
  echo ">>> NOTE: CSV-Succeeded wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${QUAY_INSTALL_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath clusterserviceversions.operators.coreos.com "${csvName}" "${QUAY_NAMESPACE}" '{.status.phase}' Succeeded Failed "CSV ${csvName} phase"; then
  _prop "csv_phase" "Succeeded"
else
  _prc=$?
  if (( _prc == 3 )); then
    _classify "quay-csv-failed" "CSV ${csvName} reached phase Failed"
  elif (( _prc == 2 )); then
    _classify "quay-subscription-query-failed" "3 consecutive CSV queries for ${csvName} failed (API/RBAC error, not absence)"
  else
    _classify "quay-csv-timeout" "CSV ${csvName} not Succeeded after ${QUAY_INSTALL_TIMEOUT}s (phase: ${_poll_last:-unknown})"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> quay-operator CSV Succeeded"

# --- Secret init-config-bundle-secret (data.config.yaml verbatim from
#     policy-install-quay.yaml: user initialize, superusers [quayadmin]) ---
if oc get secret init-config-bundle-secret -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
  _prop "init_bundle_secret" "adopted"
else
  _bundle_tmp=$(mktemp /tmp/quay-config-bundle.XXXXXX)
  cat > "${_bundle_tmp}" <<'BUNDLEEOF'
FEATURE_USER_INITIALIZE: true
BROWSER_API_CALLS_XHR_ONLY: false
SUPER_USERS:
- quayadmin
FEATURE_USER_CREATION: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
FEATURE_QUOTA_MANAGEMENT: true
BUNDLEEOF
  if oc create secret generic init-config-bundle-secret -n "${QUAY_NAMESPACE}" --from-file=config.yaml="${_bundle_tmp}" 2>&1; then
    _prop "init_bundle_secret" "created"
  elif oc get secret init-config-bundle-secret -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
    _prop "init_bundle_secret" "race-tolerated"
  else
    _classify "quay-secret-error" "failed to create Secret init-config-bundle-secret in ${QUAY_NAMESPACE}"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
  rm -f "${_bundle_tmp}"
fi

# --- Wait for the QuayRegistry CRD to report Established=True BEFORE the first
#     QuayRegistry call. The CRD object is stored when the CSV installs it, but
#     the API serves it only once Established=True; a create against an
#     unserved CRD fails and the get fallback fails too, so the create would
#     exit quay-registry-error. Check the condition, not .metadata.name (which
#     is readable as soon as the object exists). ---
_crd_want=$(( $(date +%s) + 60 ))
_poll_deadline=$(_clamp_deadline "${_crd_want}")
if _poll_jsonpath customresourcedefinitions quayregistries.quay.redhat.com "" '{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' '@contains:Established=True' '' "quayregistry CRD"; then
  _prop "quayregistry_crd" "Established"
else
  _prc=$?
  if (( _prc == 2 )); then
    _classify "quay-registry-query-failed" "3 consecutive CRD queries failed (API/RBAC error, not absence)"
  else
    _classify "quay-registry-crd-missing" "CRD quayregistries.quay.redhat.com not Established within 60s of CSV Succeeded"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi

# --- QuayRegistry registry (components objectstorage+tls managed, config
#     bundle wired) ---
if oc get quayregistries.quay.redhat.com registry -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
  _prop "quay_registry" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: registry
  namespace: ${QUAY_NAMESPACE}
spec:
  configBundleSecret: init-config-bundle-secret
  components:
    - kind: objectstorage
      managed: true
    - managed: true
      kind: tls
EOF
  then
    if oc get quayregistries.quay.redhat.com registry -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
      _prop "quay_registry" "race-tolerated"
    else
      _classify "quay-registry-error" "failed to create QuayRegistry registry in ${QUAY_NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "quay_registry" "created"
  fi
fi

# --- Wait for QuayRegistry Available=True ---
echo ">>> PHASE: waiting for QuayRegistry registry Available (timeout: ${QUAY_REGISTRY_TIMEOUT}s)"
_reg_want=$(( $(date +%s) + QUAY_REGISTRY_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_reg_want}")
if (( _poll_deadline < _reg_want )); then
  echo ">>> NOTE: QuayRegistry wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${QUAY_REGISTRY_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath quayregistries.quay.redhat.com registry "${QUAY_NAMESPACE}" \
    '{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' '@contains:Available=True' '' "QuayRegistry registry conditions"; then
  _prop "quay_registry_available" "True"
else
  _prc=$?
  if (( _prc == 2 )); then
    _classify "quay-registry-query-failed" "3 consecutive QuayRegistry queries failed (API/RBAC error, not absence)"
  else
    _classify "quay-registry-timeout" "QuayRegistry registry never reported Available=True within ${QUAY_REGISTRY_TIMEOUT}s (last: $(printf '%s' "${_poll_last:-absent}" | tr '\n' ' '))"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> QuayRegistry registry Available"

# --- create-admin-user machinery: SA/Role/RoleBinding (policy-install-quay)
#     and the Job (policy-config-quay) that initializes the Quay DB and creates
#     the quayadmin / quaydevel / quay-pull-secret secrets, org devel and repo
#     devel/example. The Job body is ported verbatim from the policy.
#     The Job is first-run-only by construction (its own guard exits 1 when
#     the quaydevel secret already exists), so: all three secrets present =>
#     adopt and skip; otherwise delete any stale Job and re-create it.
# The policy Job creates four secrets: quayadmin (admin token/password/basic),
# quaydevel (the devel user), quay-pull-secret (dockerconfigjson) and
# quay-integration (an automation token). All four must be present before the
# Job is considered done.
_quay_admin_secrets_present() {
  local _s
  for _s in quayadmin quaydevel quay-pull-secret quay-integration; do
    if ! oc get secret "${_s}" -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

if _quay_admin_secrets_present; then
  _prop "quay_admin_secrets" "adopted"
  _prop "quay_admin_job" "skipped-existing-secrets"
  echo ">>> create-admin-user: quayadmin/quaydevel/quay-pull-secret already present - adopting"
else
  echo ">>> PHASE: create-admin-user (Quay DB initialize, admin + devel user secrets)"
  cat <<EOF | oc create -f - 2>&1 || true
apiVersion: v1
kind: ServiceAccount
metadata:
  name: create-admin-user
  namespace: ${QUAY_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: create-admin-user
  namespace: ${QUAY_NAMESPACE}
rules:
  - apiGroups:
      - ""
    resources:
      - secrets
    verbs:
      - get
      - list
      - create
      - patch
      - update
      - delete
  - apiGroups:
      - route.openshift.io
    resources:
      - routes
    verbs:
      - get
      - list
  - apiGroups:
      - quay.redhat.com
    resources:
      - quayregistries
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: create-admin-user
  namespace: ${QUAY_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: create-admin-user
subjects:
  - kind: ServiceAccount
    name: create-admin-user
    namespace: ${QUAY_NAMESPACE}
EOF
  for _obj in serviceaccount/create-admin-user role/create-admin-user rolebinding/create-admin-user; do
    if ! oc get "${_obj}" -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
      _classify "quay-admin-rbac-error" "missing ${_obj} in ${QUAY_NAMESPACE} after the create attempt"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  done
  _prop "quay_admin_rbac" "present"

  # The policy Job is single-shot, not idempotent: it exits 1 when the
  # quaydevel secret already exists, and it exits 1 when Quay answers
  # "non-empty database" to /api/v1/user/initialize. So it can only populate an
  # EMPTY registry. A quayadmin secret without the rest means the database was
  # already initialized and the remaining objects are gone: re-running the Job
  # cannot repair that, and reporting it as an install failure would hide the
  # real cause. Fail fast with its own class instead.
  if oc get secret quayadmin -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
    _classify "quay-admin-partial-state" "quayadmin exists but quaydevel/quay-pull-secret/quay-integration are not all present; the policy Job cannot re-initialize an already-initialized Quay database (see policy-config-quay.yaml create-admin-user)"
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
  fi

  if oc get job create-admin-user -n "${QUAY_NAMESPACE}" >/dev/null 2>&1; then
    echo ">>> deleting stale Job create-admin-user (admin secrets absent)"
    oc delete job create-admin-user -n "${QUAY_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=60s 2>&1 || true
    _prop "quay_admin_job_stale_deleted" "true"
  fi
  cat <<'JOBEOF' | oc create -f - 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: create-admin-user
  namespace: local-quay
spec:
  template:
    spec:
      containers:
        - command:
            - /bin/bash
            - -c
            - |
              #!/usr/bin/env bash

              function quay_cmd() {
                DATA='{}'
                if [ ! -z "$4" ]; then
                  DATA=$4
                fi
                echo "[$1] $2 $3 --data $DATA" 1>&2
                AUTH="Fake: dummy"
                if [ $1 = "Basic" ]; then
                  COUNT=$(oc -n $QUAY_NAMESPACE get --ignore-not-found=true secret $QUAY_USER_SECRET | wc -l)
                  if [ $COUNT -gt 1 ]; then
                      BASIC=$(oc -n $QUAY_NAMESPACE extract secret/$QUAY_USER_SECRET --keys=basic --to=-)
                  fi
                  AUTH="Authorization: Basic $BASIC"

                elif [ $1 = "Bearer" ]; then
                  AUTH="Authorization: Bearer $TOKEN"
                fi
                curl -X $2 $CURL_OPTS -H 'Content-Type: application/json'  -H "$AUTH" https://$QUAY_HOST$3 --data "$DATA"
                echo "[INFO] Success" 1>&2
              }
              echo -n "Waiting for the Quay Registry CR to be available ."
              RC=$(oc wait QuayRegistry -n local-quay registry --for=condition=Available=true > /dev/null 2>&1;echo $?)

              while [ $RC -ne 0 ]; do
                sleep 2
                echo -n "."
                RC=$(oc wait QuayRegistry -n local-quay registry --for=condition=Available=true > /dev/null 2>&1;echo $?)
              done
              echo "done"

              CURL_OPTS="-fsk"
              QUAY_ADMIN=quayadmin
              QUAY_USER=quaydevel
              QUAY_USER_SECRET=$QUAY_USER
              QUAY_NAMESPACE=local-quay
              QUAY_HOST=$(oc get route -n $QUAY_NAMESPACE registry-quay -o jsonpath='{.spec.host}')
              QUAY_ORG=devel
              QUAY_ORG_EMAIL=devel@myorg.com
              QUAY_REPO=example
              if [ $? -ne 0 ]; then
                echo "Quay route does not exist yet, please wait and try again."
                exit 1
              fi
              RESULT=$(oc get secret -n $QUAY_NAMESPACE $QUAY_USER_SECRET)
              if [ $? -eq 0 ]; then
                echo "Quay user configuration secret already exists: $QUAY_USER_SECRET in namespace $QUAY_NAMESPACE"
                exit 1
              fi

              ADMINPASS=`head -c 8 /dev/urandom | base64 | sed 's/=//'`
              BASE64AUTH=`echo -n $QUAY_USER:$QUAY_PASSWORD | base64 -w0`
              RESULT=$(curl -X POST -k -s https://$QUAY_HOST/api/v1/user/initialize --header 'Content-Type: application/json' --data "{ \"username\": \"quayadmin\", \"password\":\"${ADMINPASS}\", \"email\": \"quayadmin@example.com\", \"access_token\": true}")
              echo "$RESULT" | grep -q "non-empty database"
              if [ $? -eq 0 ]; then
                echo "Quay user configuration failed, the database has been initialized."
                exit 1
              else
                echo "[INFO] Destroy any previous secrets ..."
                oc -n $QUAY_NAMESPACE delete --ignore-not-found=true secret $QUAY_USER_SECRET

                echo "[INFO] Creating quay admin secret quayadmin ..."
                TOKEN=$(echo "$RESULT" | tr ',' '\n' | grep access_token | awk -F: '{print $2}' | sed 's/"//g')
                oc -n $QUAY_NAMESPACE create secret generic quayadmin --from-literal=token=$TOKEN --from-literal=password=$ADMINPASS --from-literal=basic="$BASE64AUTH"

                echo "[INFO] Creating $QUAY_USER user ..."
                RESPONSE=$(quay_cmd Bearer POST /api/v1/superuser/users/ "{ \"username\": \"$QUAY_USER\", \"email\": \"$QUAY_USER_EMAIL\", \"access_token\": true}")

                QUAY_PASSWORD=$(echo $RESPONSE | tr ',' '\n' | grep '"password"' | cut -d \" -f 4)
                BASE64AUTH=`echo -n $QUAY_USER:$QUAY_PASSWORD | base64 -w0`

                echo "[INFO] Creating $QUAY_USER_SECRET secret ..."
                oc -n $QUAY_NAMESPACE create secret generic $QUAY_USER_SECRET --from-literal=password="$QUAY_PASSWORD" --from-literal=basic="$BASE64AUTH"

                echo "[INFO] Creating quay-pull-secret ..."
                echo -e "{ \"auths\": { \"$QUAY_HOST\": { \"auth\": \"$BASE64AUTH\" } }}" | oc -n $QUAY_NAMESPACE create secret generic quay-pull-secret --from-file=.dockerconfigjson=/dev/stdin --type=kubernetes.io/dockerconfigjson

                echo "[INFO] Creating quay integration token secret ..."
                oc -n $QUAY_NAMESPACE create secret generic quay-integration --from-literal=token=$TOKEN
              fi

              echo "[INFO] Looking for initial organization ..."
              COUNT=$(quay_cmd Bearer GET /api/v1/organization/$QUAY_ORG | grep -v not_found | wc -l)
              if [ $COUNT = 0 ]; then
                echo "[INFO] Creating $QUAY_ORG org ..."
                # Email cannot be shared with the initial user
                quay_cmd Bearer POST /api/v1/organization/ "{\"name\": \"$QUAY_ORG\", \"email\": \"$QUAY_ORG_EMAIL\" }"
                quay_cmd Basic GET /api/v1/organization/$QUAY_ORG
              fi

              echo "[INFO] Looking for org application ..."
              # The only way to get another OAuth token is to go to: Organization -> Applications -> {app} -> Generate Token
              # If there was a programatic way to do it here, we could avoid the problem with the bearer token expiring after 150min
              APPLICATION=automation
              COUNT=$(quay_cmd Bearer GET /api/v1/organization/$QUAY_ORG/applications | grep $APPLICATION | wc -l)
              if [ $COUNT = 0 ]; then
                echo "[INFO] Creating $APPLICATION application..."
                quay_cmd Bearer POST /api/v1/organization/$QUAY_ORG/applications "{\"name\": \"$QUAY_ORG-automation\", \"description\": \"automation app\" }"
              fi

              echo "[INFO] Looking for initial repo ..."
              COUNT=$(quay_cmd Bearer GET /api/v1/repository/$QUAY_ORG/$QUAY_REPO | grep -v not_found | wc -l)
              if [ $COUNT = 0 ]; then
                echo "[INFO] Creating $QUAY_REPO repo..."
                quay_cmd Bearer POST /api/v1/repository "{\"namespace\":\"$QUAY_ORG\", \"repository\":\"$QUAY_REPO\", \"visibility\":\"public\", \"description\":\"Development Repo\", \"repo_kind\":\"image\"}"
              fi

              echo "[INFO] Looking for $QUAY_ORG members ..."
              COUNT=$(quay_cmd Bearer GET /api/v1/organization/$QUAY_ORG/team/owners/members | grep "name\": \"$QUAY_USER\"" | wc -l)
              if [ $COUNT = 0 ]; then
                echo "[INFO] Associating $QUAY_USER with $QUAY_ORG ..."
                quay_cmd Bearer PUT /api/v1/organization/$QUAY_ORG/team/owners/members/$QUAY_USER '{}'
              fi

              echo "[INFO] Looking for $QUAY_REPO admins ..."
              COUNT=$(quay_cmd Bearer GET /api/v1/repository/$QUAY_ORG/$QUAY_REPO/permissions/user/$QUAY_USER | grep '"role": "admin"' | wc -l)
              if [ $COUNT = 0 ]; then
                echo "[INFO] Give $QUAY_USER admin rights to the repo ..."
                quay_cmd Bearer PUT /api/v1/repository/$QUAY_ORG/$QUAY_REPO/permissions/user/$QUAY_USER '{ "role": "admin"}'
              fi

              echo "[INFO] Job finished"
          image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
          imagePullPolicy: Always
          name: create-admin-user
      dnsPolicy: ClusterFirst
      restartPolicy: Never
      serviceAccount: create-admin-user
      serviceAccountName: create-admin-user
      terminationGracePeriodSeconds: 30
JOBEOF
  _job_deadline=$(_clamp_deadline $(( $(date +%s) + QUAY_ADMIN_JOB_TIMEOUT )))
  _job_left=$(( _job_deadline - $(date +%s) ))
  if (( _job_left < 10 )); then _job_left=10; fi
  if ! oc wait --for=condition=Complete job/create-admin-user -n "${QUAY_NAMESPACE}" --timeout="${_job_left}s" 2>&1; then
    _job_failed=$(oc get job create-admin-user -n "${QUAY_NAMESPACE}" -o jsonpath='{.status.failed}' 2>/dev/null) || _job_failed=""
    echo ">>> DIAG: create-admin-user Job logs (tail 200):"
    oc logs job/create-admin-user -n "${QUAY_NAMESPACE}" --tail=200 2>&1 | head -c 65536 || true
    if [[ "${_job_failed}" == "1" ]]; then
      _classify "quay-admin-job-failed" "create-admin-user Job reported failed pods"
    else
      _classify "quay-admin-job-timeout" "create-admin-user Job not Complete within ${QUAY_ADMIN_JOB_TIMEOUT}s (failed=${_job_failed:-none})"
    fi
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
  fi
  if ! _quay_admin_secrets_present; then
    echo ">>> DIAG: create-admin-user Job logs (tail 200):"
    oc logs job/create-admin-user -n "${QUAY_NAMESPACE}" --tail=200 2>&1 | head -c 65536 || true
    _classify "quay-admin-secrets-missing" "Job create-admin-user completed but quayadmin/quaydevel/quay-pull-secret are not all present"
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
  fi
  _prop "quay_admin_job" "completed"
  _prop "quay_admin_secrets" "created"
fi

for _s in quayadmin quaydevel quay-pull-secret quay-integration; do
  _prop "secret_${_s//-/_}" "present"
done

_prop "quay_deployed" "true"
echo ">>> PHASE: Quay deployed (operator + registry + admin secrets)"
true
