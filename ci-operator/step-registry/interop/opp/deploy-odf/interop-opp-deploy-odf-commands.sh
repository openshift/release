#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit
# bash >= 5.2: '&' in ${var//pat/repl} expands to the match; we need literal
# ampersands in the XML escapes below.
shopt -u patsub_replacement 2>/dev/null || true

# INTEROP-9710 workaround: install ODF (odf-operator) plus the StorageCluster,
# NooBaa BackingStore and BucketClass directly via OLM on OCP 5.x lanes, where
# ACM 2.17's governance-policy-addon-controller gates OperatorPolicy on
# openshiftVersion-major == "4" (no Subscription -> no CSV -> no StorageCluster
# CRD -> no ODF). Replicates policy-odf.yaml (namespace/OperatorGroup/
# Subscription), policy-odf-cluster.yaml (StorageCluster ocs-storagecluster,
# incl. the noobaa-* resource requests/limits and the 100Gi/Block deviceset)
# and policy-odf-noobaa.yaml (BackingStore noobaa-pv-backing-store,
# BucketClass noobaa-default-bucket-class) object-for-object, so the
# downstream interop-opp-odf-health step finds identical objects.
#
# Capture/JUnit contract (same shape as interop-opp-deploy-acs, authority
# opp-interop-testing docs/design/acs-deploy-evidence.md):
#   * Single preserved suite/testcase id (odf-deploy /
#     lp-interop--OPP--odf-deploy); classification appears only in the
#     failure type/message attributes.
#   * A default-failing JUnit case is pre-seeded on disk before any work and
#     replaced in place at completion (atomic mktemp+mv), so a SIGKILL still
#     leaves a failing case (missing JUnit reads as unknown, never green).
#   * Self-disable: when operatorpolicy-odf-operator is Compliant with a
#     matching channel, the CSV is Succeeded AND StorageCluster
#     ocs-storagecluster is phase Ready, emit workaround_removal_ready=true
#     and exit 0.
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
_jn="odf-deploy"
_jsuite="lp-interop--OPP--${_jn}"
_jfile="${ARTIFACT_DIR}/junit_lp-interop--OPP--${_jn}.xml"
_class="odf-unclassified:no-classification"
_class_detail="no classification recorded"
_junit_start=$(date +%s)
_junit_done=0
_props="${ARTIFACT_DIR}/odf-deploy-properties.txt"

# --- Shared work deadline (single wall-clock authority) ---
# The step ref.yaml timeout minus its grace_period is the work budget. Setup,
# precondition, every wait, classification, and diagnostics all charge against
# this ONE deadline, so a slow setup or an oc request that straddles a poll
# deadline cannot push classification/JUnit past the budget (and so cannot
# leave TERM to record StepTerminated in place of a real class).
# Reserves subtracted from the deadline when capping a phase:
#   _diag_reserve        bounded diagnostics (4 x 20s request-timeout) + JUnit
#   _oc_overrun_reserve  one in-flight 20s oc request at a phase deadline
_work_budget=4020
_diag_reserve=120
_oc_overrun_reserve=25
_work_deadline=$(( _junit_start + _work_budget ))

# _classify <type> <detail>: record the failure classification (first match
# wins; called in precedence order by the detection code).
_classify() {
  if [[ "${_class}" == "odf-unclassified:no-classification" ]]; then
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
    if [[ "${_class}" == odf-unclassified:* ]]; then
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
# ODF_CHANNEL is accepted as a legacy alias so an existing lane override keeps
# working; ODF_OPERATOR_CHANNEL wins when both are set.
ODF_OPERATOR_CHANNEL="${ODF_OPERATOR_CHANNEL:-${ODF_CHANNEL:-stable-4.22}}"
ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
ODF_CSV_WAIT_TIMEOUT="${ODF_CSV_WAIT_TIMEOUT:-300}"
ODF_INSTALL_TIMEOUT="${ODF_INSTALL_TIMEOUT:-600}"
ODF_STORAGECLUSTER_TIMEOUT="${ODF_STORAGECLUSTER_TIMEOUT:-1800}"
NOOBAA_BACKINGSTORE_TIMEOUT="${NOOBAA_BACKINGSTORE_TIMEOUT:-600}"
ODF_DEVICESET_STORAGECLASS="${ODF_DEVICESET_STORAGECLASS:-}"
ODF_REPORT_ONLY="${ODF_REPORT_ONLY:-0}"

if ! [[ "${ODF_OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: invalid ODF_OPERATOR_CHANNEL '${ODF_OPERATOR_CHANNEL}'"
  _classify "odf-invalid-input" "ODF_OPERATOR_CHANNEL failed validation"
  exit 2
fi
if ! [[ "${ODF_DEVICESET_STORAGECLASS}" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
  echo "ERROR: invalid ODF_DEVICESET_STORAGECLASS '${ODF_DEVICESET_STORAGECLASS}'"
  _classify "odf-invalid-input" "ODF_DEVICESET_STORAGECLASS failed validation"
  exit 2
fi
for _v in ODF_CSV_WAIT_TIMEOUT ODF_INSTALL_TIMEOUT ODF_STORAGECLUSTER_TIMEOUT NOOBAA_BACKINGSTORE_TIMEOUT; do
  _v_raw="${!_v}"
  # Bounded to 9 digits so the 10# conversion below cannot wrap a 64-bit
  # integer into the accepted range.
  if ! [[ "${_v_raw}" =~ ^[0-9]{1,9}$ ]]; then
    echo "ERROR: ${_v} must be integer seconds in 1..2700 (got '${_v_raw}')"
    _classify "odf-invalid-input" "${_v} failed validation"
    exit 2
  fi
  # Normalize to decimal before any arithmetic sees it: bash reads a
  # leading-zero literal as OCTAL ("0600" is 384s) and "0900" aborts the
  # script outright.
  printf -v "${_v}" '%d' "$(( 10#${_v_raw} ))"
  if (( ${!_v} < 1 || ${!_v} > 2700 )); then
    echo "ERROR: ${_v} must be integer seconds in 1..2700 (got '${_v_raw}')"
    _classify "odf-invalid-input" "${_v} failed validation"
    exit 2
  fi
done

# Budget invariant (ref.yaml: timeout 70m = 4200s, grace_period 180s => 4020s
# work; overhead 180s + precondition <=120s + diagnostics <=120s => phase
# budget 3600s). ODF is the slowest of the three installs: a 3 x 100Gi gp3
# deviceset plus Ceph and NooBaa convergence is 15-25 minutes on AWS, so the
# StorageCluster wait alone defaults to 1800s. The four waits are sequential
# and each independently bounded, so the SUM must multiply out; per-variable
# 1..2700 alone admits 4 x 2700s and would let TERM record StepTerminated
# instead of a real classification. Fail-fast half (exit 2); the runtime half
# is _work_deadline, which charges elapsed setup and caps every phase deadline.
_phase_sum=$(( ODF_CSV_WAIT_TIMEOUT + ODF_INSTALL_TIMEOUT + ODF_STORAGECLUSTER_TIMEOUT + NOOBAA_BACKINGSTORE_TIMEOUT ))
if (( _phase_sum > 3600 )); then
  echo "ERROR: phase waits sum to ${_phase_sum}s, must be <= 3600s (work budget 4020s - overhead 180s - precondition 120s - diagnostics 120s)"
  _classify "odf-invalid-input" "phase wait sum ${_phase_sum}s exceeds the step work budget"
  exit 2
fi

echo ">>> PHASE: deploy ODF (channel: ${ODF_OPERATOR_CHANNEL}, namespace: ${ODF_NAMESPACE}, CSV name wait: ${ODF_CSV_WAIT_TIMEOUT}s, CSV wait: ${ODF_INSTALL_TIMEOUT}s, StorageCluster wait: ${ODF_STORAGECLUSTER_TIMEOUT}s, BackingStore wait: ${NOOBAA_BACKINGSTORE_TIMEOUT}s)"

# --- Diagnostics: bounded (last 50 events, <=256KiB/object) ---
_dump_diagnostics() {
  echo ">>> DIAG: Subscription (OLM, fully-qualified):"
  oc get subscription.operators.coreos.com odf-operator -n "${ODF_NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
  echo ">>> DIAG: events in ${ODF_NAMESPACE} (last 50):"
  oc get events -n "${ODF_NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: events in openshift-marketplace (last 50):"
  oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: CSVs in ${ODF_NAMESPACE}:"
  oc get csv -n "${ODF_NAMESPACE}" 2>&1 | head -50 || true
  echo ">>> DIAG: StorageCluster ocs-storagecluster status:"
  oc get storageclusters.ocs.openshift.io ocs-storagecluster -n "${ODF_NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
  echo ">>> DIAG: noobaa CRs in ${ODF_NAMESPACE}:"
  oc get backingstores.noobaa.io,bucketclasses.noobaa.io,noobaa.noobaa.io -n "${ODF_NAMESPACE}" 2>&1 | head -50 || true
}

if [[ "${ODF_REPORT_ONLY}" == "1" ]]; then
  # Detection, not gating: report object states and exit 0. Runs before the
  # packagemanifest precondition on purpose (detection must work when the
  # catalog is absent or erroring) and before the self-disable check so the
  # full property set is recorded even when an OperatorPolicy owns the install.
  _sub=$(oc get subscription.operators.coreos.com odf-operator -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _sub=""
  _csvp=$(oc get csv -n "${ODF_NAMESPACE}" -l "operators.coreos.com/odf-operator.${ODF_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _csvp=""
  _scp=$(oc get storageclusters.ocs.openshift.io ocs-storagecluster -n "${ODF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null) || _scp=""
  _pm=$(oc get packagemanifest odf-operator -n openshift-marketplace -o name 2>/dev/null) || _pm=""
  _prop "report_only" "true"
  _prop "channel_observed" "${_sub:-absent}"
  _prop "csv_phase" "${_csvp:-absent}"
  _prop "storagecluster_phase" "${_scp:-absent}"
  _prop "packagemanifest" "$([[ -n "${_pm}" ]] && echo present || echo absent)"
  echo ">>> REPORT_ONLY: channel=${_sub:-absent} csv=${_csvp:-absent} storagecluster=${_scp:-absent} packagemanifest=$([[ -n "${_pm}" ]] && echo present || echo absent)"
  exit 0
fi

# --- Self-disable predicate ---
# operatorpolicy-odf-operator Compliant AND subscription channel matches AND
# CSV Succeeded AND StorageCluster ocs-storagecluster phase Ready.
# Queried cluster-wide by name (ACM installs the OperatorPolicy in the managed
# cluster namespace, local-cluster) and the observed namespace is recorded.
_prop "channel_requested" "${ODF_OPERATOR_CHANNEL}"
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
' operatorpolicy-odf-operator "${ODF_OPERATOR_CHANNEL}" 2>/dev/null) || _sd_out="absent - -"
    _sd_ok="absent" _sd_ns="-" _sd_ch="-"
    read -r _sd_ok _sd_ns _sd_ch <<<"${_sd_out}" || true
    _prop "operatorpolicy_namespace" "${_sd_ns:-unknown}"
    _prop "operatorpolicy_channel" "${_sd_ch:-unknown}"
    if [[ "${_sd_ok}" == "true" ]]; then
      _existing_csv=$(oc get csv -n "${ODF_NAMESPACE}" -l "operators.coreos.com/odf-operator.${ODF_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _existing_csv=""
      _sc_phase=$(oc get storageclusters.ocs.openshift.io ocs-storagecluster -n "${ODF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null) || _sc_phase=""
      if [[ "${_existing_csv}" == "Succeeded" && "${_sc_phase}" == "Ready" ]]; then
        echo ">>> workaround_removal_ready=true (OperatorPolicy Compliant, channel ${_sd_ch}, CSV Succeeded, StorageCluster Ready) - not installing"
        _prop "workaround_removal_ready" "true"
        _prop "odf_subscription" "adopted"
        _prop "csv_phase" "Succeeded"
        _prop "storagecluster_phase" "Ready"
        exit 0
      fi
    elif [[ "${_sd_ch}" != "-" && "${_sd_ch}" != "${ODF_OPERATOR_CHANNEL}" ]]; then
      echo ">>> NOTE: OperatorPolicy channel '${_sd_ch}' != requested '${ODF_OPERATOR_CHANNEL}': self-disable withheld, installing"
      _prop "channel_self_disable_withheld" "${_sd_ch}!=${ODF_OPERATOR_CHANNEL}"
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
  if _pm_raw=$(oc get packagemanifest odf-operator -n openshift-marketplace -o json 2>&1); then
    _precondition_ok=true
    break
  fi
  if printf '%s' "${_pm_raw}" | grep -qi "not found"; then
    _classify "odf-catalog-missing" "packagemanifest odf-operator not found in openshift-marketplace (successful query)"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
  _backoff=$(( _attempt == 1 ? 5 : _attempt == 2 ? 15 : 30 ))
  echo ">>> precondition query failed (attempt ${_attempt}/3), retrying in ${_backoff}s: $(printf '%s' "${_pm_raw}" | head -1)"
  sleep "${_backoff}"
done
if [[ "${_precondition_ok}" != "true" ]]; then
  _classify "odf-catalog-query-failed" "packagemanifest query errored after 3 attempts (non-reverting class): $(printf '%s' "${_pm_raw}" | head -1)"
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
' "${ODF_OPERATOR_CHANNEL}" 2>/dev/null) || _channel_ok="error"
case "${_channel_ok}" in
  absent*)
    _classify "odf-catalog-missing" "channel '${ODF_OPERATOR_CHANNEL}' not listed for odf-operator (${_channel_ok#absent })"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
  error)
    _classify "odf-catalog-query-failed" "packagemanifest channel listing unparseable (query succeeded but returned non-JSON)"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
esac
echo ">>> precondition: odf-operator present; channel ${ODF_OPERATOR_CHANNEL} head: ${_channel_ok#ok }"

# --- Create-if-absent: namespace (policy-odf.yaml carries the
#     cluster-monitoring label; ensured idempotently) ---
if oc get namespace "${ODF_NAMESPACE}" >/dev/null 2>&1; then
  _prop "odf_namespace" "adopted"
else
  if oc create namespace "${ODF_NAMESPACE}" 2>&1; then
    _prop "odf_namespace" "created"
  elif oc get namespace "${ODF_NAMESPACE}" >/dev/null 2>&1; then
    _prop "odf_namespace" "race-tolerated"
  else
    _classify "odf-namespace-error" "failed to create namespace ${ODF_NAMESPACE}"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
fi
oc label namespace "${ODF_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite >/dev/null 2>&1 || true

# --- Create-if-absent: OperatorGroup (name openshift-storage-operatorgroup,
#     targetNamespaces [openshift-storage]; any existing group is adopted; a
#     second group in one namespace puts CSVs into TooManyOperatorGroups).
#     oc create, not apply: if a second writer (a live OperatorPolicy) wins the
#     race, create fails AlreadyExists and we adopt; never overwrite the
#     existing spec.targetNamespaces. ---
if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${ODF_NAMESPACE}" -o name 2>/dev/null)" ]]; then
  _prop "odf_operatorgroup" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: ${ODF_NAMESPACE}
spec:
  targetNamespaces:
    - ${ODF_NAMESPACE}
EOF
  then
    if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${ODF_NAMESPACE}" -o name 2>/dev/null)" ]]; then
      _prop "odf_operatorgroup" "race-tolerated"
      echo ">>> NOTE: OperatorGroup created concurrently by another writer - adopting"
    else
      _classify "odf-operatorgroup-create-error" "failed to create OperatorGroup openshift-storage-operatorgroup in ${ODF_NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "odf_operatorgroup" "created"
  fi
fi

# --- Create-if-absent: Subscription (oc create, not apply: if a second writer
#     (a live OperatorPolicy) wins the race, create fails AlreadyExists and
#     we adopt; never overwrite) ---
if oc get subscription.operators.coreos.com odf-operator -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
  _existing_ch=$(oc get subscription.operators.coreos.com odf-operator -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _existing_ch="unknown"
  _prop "odf_subscription" "adopted"
  _prop "channel_observed" "${_existing_ch:-empty}"
  if [[ -n "${_existing_ch}" && "${_existing_ch}" != "${ODF_OPERATOR_CHANNEL}" ]]; then
    echo ">>> NOTE: existing Subscription channel '${_existing_ch}' != requested '${ODF_OPERATOR_CHANNEL}' - adopting, not overwriting (a live OperatorPolicy is the owner)"
    _prop "channel_mismatch" "${_existing_ch}!=${ODF_OPERATOR_CHANNEL}"
  fi
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: ${ODF_NAMESPACE}
spec:
  channel: "${ODF_OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  then
    if oc get subscription.operators.coreos.com odf-operator -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
      _prop "odf_subscription" "race-tolerated"
      _prop "channel_observed" "$(oc get subscription.operators.coreos.com odf-operator -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo unknown)"
      echo ">>> NOTE: Subscription created concurrently by another writer - adopting"
    else
      _classify "odf-subscription-create-error" "failed to create Subscription odf-operator"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "odf_subscription" "created"
    _prop "channel_observed" "${ODF_OPERATOR_CHANNEL}"
  fi
fi

# --- Wait for the CSV name (read status.currentCSV; the patch version is
#     never hardcoded). Elapsed-time deadline, so a slow-but-successful
#     response is charged against the budget. ---
echo ">>> PHASE: waiting for the odf-operator CSV name (timeout: ${ODF_CSV_WAIT_TIMEOUT}s)"
_csv_want=$(( $(date +%s) + ODF_CSV_WAIT_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_csv_want}")
if (( _poll_deadline < _csv_want )); then
  echo ">>> NOTE: CSV-name wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${ODF_CSV_WAIT_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath subscription.operators.coreos.com odf-operator "${ODF_NAMESPACE}" '{.status.currentCSV}' '@any' '' "odf-operator currentCSV"; then
  csvName="${_poll_last}"
  _prop "csv_name" "${csvName}"
else
  _prc=$?
  _cond=$(oc get subscription.operators.coreos.com odf-operator -n "${ODF_NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {end}' 2>/dev/null) || _cond=""
  if (( _prc == 2 )); then
    _classify "odf-subscription-query-failed" "3 consecutive subscription queries failed (rc captured; API/RBAC error, not absence)"
  else
    case "${_cond}" in
      *CatalogSourcesUnhealthy=True*) _classify "odf-catalog-missing" "Subscription condition CatalogSourcesUnhealthy=True" ;;
      *ConstraintsNotSatisfiable*)    _classify "odf-subscription-unsatisfiable" "Subscription condition ConstraintsNotSatisfiable" ;;
      *InstallPlanMissing*)           _classify "odf-installplan-missing" "Subscription condition InstallPlanMissing" ;;
      *InstallPlanFailed*)            _classify "odf-installplan-failed" "Subscription condition InstallPlanFailed" ;;
      *)                              _classify "odf-csv-timeout" "no currentCSV after ${ODF_CSV_WAIT_TIMEOUT}s (conditions: ${_cond:-none})" ;;
    esac
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> odf-operator CSV: ${csvName}"

# --- Wait for CSV Succeeded (a not-yet-created CSV object is waited out, not
#     classified as an API failure). ---
echo ">>> PHASE: waiting for CSV ${csvName} Succeeded (timeout: ${ODF_INSTALL_TIMEOUT}s)"
_install_want=$(( $(date +%s) + ODF_INSTALL_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_install_want}")
if (( _poll_deadline < _install_want )); then
  echo ">>> NOTE: CSV-Succeeded wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${ODF_INSTALL_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath clusterserviceversions.operators.coreos.com "${csvName}" "${ODF_NAMESPACE}" '{.status.phase}' Succeeded Failed "CSV ${csvName} phase"; then
  _prop "csv_phase" "Succeeded"
else
  _prc=$?
  if (( _prc == 3 )); then
    _classify "odf-csv-failed" "CSV ${csvName} reached phase Failed"
  elif (( _prc == 2 )); then
    _classify "odf-subscription-query-failed" "3 consecutive CSV queries for ${csvName} failed (API/RBAC error, not absence)"
  else
    _classify "odf-csv-timeout" "CSV ${csvName} not Succeeded after ${ODF_INSTALL_TIMEOUT}s (phase: ${_poll_last:-unknown})"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> odf-operator CSV Succeeded"

# --- Deviceset storage class (policy-odf-cluster.yaml): VSphere uses
#     thin-csi-odf (and the policy creates that StorageClass), every other
#     platform the AWS lane runs on uses gp3-csi. ODF_DEVICESET_STORAGECLASS
#     overrides the computed value. ---
_platform=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null) || _platform=""
_platform_spec=$(oc get infrastructure cluster -o jsonpath='{.spec.platformSpec.type}' 2>/dev/null) || _platform_spec=""
_prop "platform" "${_platform:-unknown}"
_is_vsphere=0
if [[ "${_platform_spec}" == "VSphere" || "${_platform}" == "VSphere" ]]; then
  _is_vsphere=1
fi
if [[ -z "${ODF_DEVICESET_STORAGECLASS}" ]]; then
  if (( _is_vsphere == 1 )); then
    ODF_DEVICESET_STORAGECLASS="thin-csi-odf"
  else
    ODF_DEVICESET_STORAGECLASS="gp3-csi"
  fi
fi
_prop "deviceset_storageclass" "${ODF_DEVICESET_STORAGECLASS}"
echo ">>> deviceset storage class: ${ODF_DEVICESET_STORAGECLASS} (platform: ${_platform:-unknown})"
if (( _is_vsphere == 1 )) && [[ "${ODF_DEVICESET_STORAGECLASS}" == "thin-csi-odf" ]]; then
  if oc get storageclass thin-csi-odf >/dev/null 2>&1; then
    _prop "thin_csi_odf_storageclass" "adopted"
  else
    cat <<EOF | oc apply -f - 2>&1
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
  name: thin-csi-odf
parameters:
  StoragePolicyName: "vSAN Default Storage Policy"
provisioner: csi.vsphere.vmware.com
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
    _prop "thin_csi_odf_storageclass" "created"
  fi
  if ! oc get storageclass "${ODF_DEVICESET_STORAGECLASS}" >/dev/null 2>&1; then
    _classify "odf-storageclass-missing" "StorageClass ${ODF_DEVICESET_STORAGECLASS} does not exist on this cluster"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
else
  if ! oc get storageclass "${ODF_DEVICESET_STORAGECLASS}" >/dev/null 2>&1; then
    _classify "odf-storageclass-missing" "StorageClass ${ODF_DEVICESET_STORAGECLASS} does not exist on this cluster (set ODF_DEVICESET_STORAGECLASS for non-AWS/non-vSphere platforms)"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
fi

# --- StorageCluster ocs-storagecluster (policy-odf-cluster.yaml): one
#     ocs-deviceset, replica 3, portable, 100Gi ReadWriteOnce Block, plus the
#     noobaa-* resource requests/limits. ---
_crd_want=$(( $(date +%s) + 60 ))
_poll_deadline=$(_clamp_deadline "${_crd_want}")
if _poll_jsonpath customresourcedefinitions storageclusters.ocs.openshift.io "" '{.metadata.name}' storageclusters.ocs.openshift.io '' "storagecluster CRD"; then
  :
else
  _prc=$?
  if (( _prc == 2 )); then
    _classify "odf-storagecluster-query-failed" "3 consecutive CRD queries failed (API/RBAC error, not absence)"
  else
    _classify "odf-storagecluster-crd-missing" "CRD storageclusters.ocs.openshift.io not established within 60s of CSV Succeeded"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
if oc get storageclusters.ocs.openshift.io ocs-storagecluster -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
  _prop "odf_storagecluster" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: ${ODF_NAMESPACE}
spec:
  resources:
    mds: {}
    mgr: {}
    mon: {}
    noobaa-core:
      limits:
        cpu: 2
        memory: 8Gi
      requests:
        cpu: 1
        memory: 4Gi
    noobaa-db:
      limits:
        cpu: 2
        memory: 8Gi
      requests:
        cpu: 1
        memory: 4Gi
    noobaa-endpoint:
      limits:
        cpu: 2
        memory: 4Gi
      requests:
        cpu: 1
        memory: 2Gi
    rgw: {}
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "100Gi"
        storageClassName: "${ODF_DEVICESET_STORAGECLASS}"
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
EOF
  then
    if oc get storageclusters.ocs.openshift.io ocs-storagecluster -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
      _prop "odf_storagecluster" "race-tolerated"
    else
      _classify "odf-storagecluster-create-error" "failed to create StorageCluster ocs-storagecluster in ${ODF_NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "odf_storagecluster" "created"
  fi
fi

# --- Wait for StorageCluster Ready (phase, not a condition) ---
echo ">>> PHASE: waiting for StorageCluster ocs-storagecluster Ready (timeout: ${ODF_STORAGECLUSTER_TIMEOUT}s)"
_sc_want=$(( $(date +%s) + ODF_STORAGECLUSTER_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_sc_want}")
if (( _poll_deadline < _sc_want )); then
  echo ">>> NOTE: StorageCluster wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${ODF_STORAGECLUSTER_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath storageclusters.ocs.openshift.io ocs-storagecluster "${ODF_NAMESPACE}" '{.status.phase}' Ready Error "StorageCluster ocs-storagecluster phase"; then
  _prop "storagecluster_phase" "Ready"
else
  _prc=$?
  if (( _prc == 3 )); then
    _classify "odf-storagecluster-failed" "StorageCluster ocs-storagecluster reached status.phase Error"
  elif (( _prc == 2 )); then
    _classify "odf-storagecluster-query-failed" "3 consecutive StorageCluster queries failed (API/RBAC error, not absence)"
  else
    _classify "odf-storagecluster-timeout" "StorageCluster ocs-storagecluster not Ready after ${ODF_STORAGECLUSTER_TIMEOUT}s (phase: ${_poll_last:-unknown})"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> StorageCluster ocs-storagecluster Ready"

# --- NooBaa BackingStore noobaa-pv-backing-store + BucketClass
#     noobaa-default-bucket-class (policy-odf-noobaa.yaml; the BucketClass
#     overrides the auto-created aws-s3 default so only pv-pool is used) ---
if oc get backingstores.noobaa.io noobaa-pv-backing-store -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
  _prop "odf_backingstore" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: noobaa.io/v1alpha1
kind: BackingStore
metadata:
  name: noobaa-pv-backing-store
  namespace: ${ODF_NAMESPACE}
spec:
  type: pv-pool
  pvPool:
    numVolumes: 3
    resources:
      limits:
        cpu: "2"
        memory: 8Gi
      requests:
        cpu: "1"
        memory: 4Gi
        storage: 100Gi
    storageClass: ocs-storagecluster-ceph-rbd
EOF
  then
    if oc get backingstores.noobaa.io noobaa-pv-backing-store -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
      _prop "odf_backingstore" "race-tolerated"
    else
      _classify "odf-backingstore-create-error" "failed to create BackingStore noobaa-pv-backing-store in ${ODF_NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "odf_backingstore" "created"
  fi
fi

if oc get bucketclasses.noobaa.io noobaa-default-bucket-class -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
  _prop "odf_bucketclass" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: noobaa.io/v1alpha1
kind: BucketClass
metadata:
  name: noobaa-default-bucket-class
  namespace: ${ODF_NAMESPACE}
spec:
  placementPolicy:
    tiers:
      - backingStores:
          - noobaa-pv-backing-store
EOF
  then
    if oc get bucketclasses.noobaa.io noobaa-default-bucket-class -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
      _prop "odf_bucketclass" "race-tolerated"
    else
      _classify "odf-bucketclass-create-error" "failed to create BucketClass noobaa-default-bucket-class in ${ODF_NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "odf_bucketclass" "created"
  fi
fi

# --- Validate the placement of noobaa-default-bucket-class (adopted,
#     race-tolerated or created): MCG/ODF can already own that name against
#     its own default backing store (type aws-s3 on AWS), and the adoption
#     above never overwrites it. Without this check the step would report
#     odf_bucketclass=adopted and bucket claims would silently use the default
#     store instead of the pv-pool this step provisions. ---
_bc_stores=$(oc get bucketclasses.noobaa.io noobaa-default-bucket-class -n "${ODF_NAMESPACE}" \
  -o jsonpath='{range .spec.placementPolicy.tiers[*].backingStores[*]}{.}{"\n"}{end}' 2>/dev/null) || _bc_stores=""
# Exact line match: a substring test would also accept
# noobaa-pv-backing-store-archive or any longer name containing the target.
if ! printf '%s\n' "${_bc_stores}" | grep -qx 'noobaa-pv-backing-store'; then
  _classify "odf-bucketclass-placement-error" "BucketClass noobaa-default-bucket-class does not use noobaa-pv-backing-store (backingStores: $(printf '%s' "${_bc_stores:-absent}" | tr '\n' ' '))"
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
_prop "bucketclass_backingstore" "noobaa-pv-backing-store"

# --- Wait for BackingStore Ready (bounded: the pv-pool provisions 3 x 100Gi
#     RBD volumes after Ceph and NooBaa are up) ---
echo ">>> PHASE: waiting for BackingStore noobaa-pv-backing-store Ready (timeout: ${NOOBAA_BACKINGSTORE_TIMEOUT}s)"
_bs_want=$(( $(date +%s) + NOOBAA_BACKINGSTORE_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_bs_want}")
if (( _poll_deadline < _bs_want )); then
  echo ">>> NOTE: BackingStore wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${NOOBAA_BACKINGSTORE_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath backingstores.noobaa.io noobaa-pv-backing-store "${ODF_NAMESPACE}" '{.status.phase}' Ready Rejected "BackingStore noobaa-pv-backing-store phase"; then
  _prop "backingstore_phase" "Ready"
else
  _prc=$?
  if (( _prc == 3 )); then
    _classify "odf-backingstore-failed" "BackingStore noobaa-pv-backing-store reached status.phase Rejected"
  elif (( _prc == 2 )); then
    _classify "odf-backingstore-query-failed" "3 consecutive BackingStore queries failed (API/RBAC error, not absence)"
  else
    _classify "odf-backingstore-timeout" "BackingStore noobaa-pv-backing-store not Ready after ${NOOBAA_BACKINGSTORE_TIMEOUT}s (phase: ${_poll_last:-unknown})"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> BackingStore noobaa-pv-backing-store Ready"

_prop "odf_deployed" "true"
echo ">>> PHASE: ODF deployed (operator + StorageCluster + NooBaa backing store and bucket class)"
true
