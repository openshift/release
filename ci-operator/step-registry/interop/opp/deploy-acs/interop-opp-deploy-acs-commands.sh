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
#          acs-catalog-query-failed; the Subscription probe decided absent in
#          both, and an undecided probe with an unavailable listing ->
#          acs-subscription-query-failed
#       3. Subscription conditions -> acs-subscription-unsatisfiable /
#          acs-installplan-missing / acs-installplan-failed /
#          acs-catalog-missing
#       4. CSV phase Failed -> acs-csv-failed
#       5. deadline -> acs-csv-timeout
#       default -> acs-unclassified:<type>/<reason> (JUnit error, never pass)
#   * Self-disable: when the operatorpolicy-rhacs-operator that owns THIS
#     step's namespace (spec.subscription.namespace) is Compliant with a
#     matching channel and the CSV the Subscription names (status.currentCSV)
#     is Succeeded, emit
#     workaround_removal_ready=true and exit 0 without installing. A failed
#     cluster-wide OperatorPolicy list is never read as "no policy": it
#     retries, then fails closed as acs-operatorpolicy-query-failed (an RBAC,
#     timeout, or transport error must not install a second Subscription).
#   * Create-if-absent only: an existing Subscription is adopted (channel
#     mismatch recorded, never overwritten; the OperatorPolicy owns it once
#     ACM 2.17.z carrying stolostron/governance-policy-addon-controller#1397
#     ships). The requested channel has to be offered by the current catalog
#     only when this step is the one that creates the Subscription: an
#     adopted Subscription's pinned channel is reported (channel_delisted)
#     and the CSV wait classifies the outcome.

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# --- API-response trace suspension: set -x prints EXPANDED arguments, and
#     ${_xtrace_log} is copied into artifacts on nonzero exit, so every
#     API-controlled value handed to printf/echo lands in the trace verbatim.
#     The sed scrub in _opp_cleanup is a credential filter, not a redaction
#     boundary for API text: _api_quiet/_api_loud bracket each block that
#     expands an API response body.
_api_trace_on=0
_api_quiet_depth=0
_api_quiet() {
  _api_quiet_depth=$(( _api_quiet_depth + 1 ))
  if [[ $- == *x* ]]; then
    _api_trace_on=1
    set +x
  fi
  return 0
}
_api_loud() {
  if (( _api_quiet_depth > 0 )); then
    _api_quiet_depth=$(( _api_quiet_depth - 1 ))
    if (( _api_quiet_depth == 0 )) && (( _api_trace_on )); then set -x; fi
  fi
  return 0
}

# shellcheck disable=SC2154
# Once-flagged like _junit_emit: a TERM/INT trap runs _on_exit -> exit,
# which fires the EXIT trap -> _on_exit again; without this guard the
# redaction/copy below (and its TRACE line) would run twice.
_cleanup_done=0
_opp_cleanup() {
  # Save xtrace log with credentials scrubbed when the step exits non-zero.
  # Takes the recorded exit status explicitly: $? here is unreliable (callers
  # run other commands first). Scope: this is a CREDENTIAL filter only. It
  # does not make the trace a safe channel for API-controlled text, which is
  # why API-response handling runs under _api_quiet instead.
  local _exit_code="${1:-0}"
  (( _cleanup_done )) && return 0
  _cleanup_done=1
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

# --- Shared work deadline (single wall-clock authority) ---
# ref.yaml: timeout 30m (1800s) − grace_period 150s = 1650s of work. Setup,
# precondition, both waits, classification, and diagnostics all charge
# against this ONE deadline, so a slow setup or an oc request that straddles
# a poll deadline cannot push classification/JUnit past the work budget (and
# so cannot leave TERM to record StepTerminated in place of acs-csv-timeout).
# Reserves subtracted from the deadline when capping a phase:
#   _diag_reserve        bounded diagnostics: five queries, each with the 20s
#                        request timeout, under a 120s cap, plus the JUnit write
#   _oc_overrun_reserve  one in-flight 20s oc request at a phase deadline
# Phase deadlines are capped at _work_deadline - both reserves.
_work_budget=1650
_diag_reserve=120
_oc_overrun_reserve=25
_work_deadline=$(( _junit_start + _work_budget ))

# _classify <type> <detail>: record the failure classification (first
# match wins; called in precedence order by the detection code).
_classify() {
  if [[ "${_class}" == "acs-unclassified:no-classification" ]]; then
    _class="${1}"
    _class_detail="${2}"
  fi
}

# _cond_classify - classify a failed install from the Subscription conditions.
# The documented failure precedence puts the Subscription conditions above the
# CSV phase and the deadline: an InstallPlan that went missing or failed, an
# unsatisfiable channel, or unhealthy catalog sources is a more specific cause
# than "the CSV is not Succeeded yet", and it has to classify the same way
# whether or not status.currentCSV is already published. Sets _cond_class and
# _cond_detail; _cond_class stays empty when no condition matched, so each call
# site keeps its own default detail. The query runs under the quiet scope: set
# -x would trace the expanded condition text into the artifact log.
typeset _cond_class="" _cond_detail=""
_cond_classify() {
  local _cond
  _api_quiet
  _cond=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {end}' 2>/dev/null) || _cond=""
  _api_loud
  _cond_class=""
  _cond_detail=""
  case "${_cond}" in
    *CatalogSourcesUnhealthy=True*) _cond_class="acs-catalog-missing"; _cond_detail="Subscription condition CatalogSourcesUnhealthy=True" ;;
    *ConstraintsNotSatisfiable*)    _cond_class="acs-subscription-unsatisfiable"; _cond_detail="Subscription condition ConstraintsNotSatisfiable" ;;
    *InstallPlanMissing*)           _cond_class="acs-installplan-missing"; _cond_detail="Subscription condition InstallPlanMissing" ;;
    *InstallPlanFailed*)            _cond_class="acs-installplan-failed"; _cond_detail="Subscription condition InstallPlanFailed" ;;
  esac
}

# _api_err_class <text> - collapse an oc error to a fixed token. The raw text
# is API/RBAC controlled and would otherwise reach the step log, the xtrace
# log, and the JUnit detail verbatim.
_api_err_class() {
  case "$1" in
    "")                                                            echo "empty" ;;
    *[Uu]nauthorized*|*"must be logged in"*)                       echo "unauthorized" ;;
    *[Ff]orbidden*|*"cannot get"*|*"cannot list"*|*"cannot create"*) echo "forbidden" ;;
    *"not found"*|*NotFound*)                                      echo "not-found" ;;
    *[Tt]imeout*|*"unable to return a response"*)                  echo "timeout" ;;
    *"no such host"*|*"connection refused"*|*"connect: "*|*EOF*)   echo "transport-error" ;;
    *)                                                             echo "other" ;;
  esac
}

# _diag_get <command...>: run one diagnostic query with stderr contained.
# The caller's jsonpath keeps API-controlled fields out of the log; stderr
# carries the raw API error, which is API-controlled text as well, so a failed
# query contributes only its classification and never the error body.
_diag_get() {
  local _errf _rc=0
  _errf=$(mktemp) || return 0
  "$@" 2>"${_errf}" || _rc=$?
  if (( _rc != 0 )); then
    printf '  (query failed: %s)\n' "$(_api_err_class "$(cat "${_errf}")")"
  fi
  rm -f "${_errf}"
  return 0
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

# _junit_emit <exit-code> - replace the seeded case IN PLACE (same
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
    _msg=$(_xml_escape "step terminated by signal ${_signal} after ${_jd}s")
    _fc=1
    _fx="<failure message=\"${_msg}\" type=\"${_type}\">${_msg}; classification at termination: $(_xml_escape "${_class}")</failure>"
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

# _on_exit <recorded-status>: once-flagged handler; TERM/INT variants pass
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

# _clamp_deadline <epoch>: cap a phase deadline at the shared work deadline
# minus the diagnostics and one-in-flight-request reserves. An oc request
# started just before the returned deadline (<=20s) therefore finishes before
# _work_deadline - _diag_reserve, leaving that reserve for classification,
# diagnostics, and JUnit. Prints the (possibly lowered) deadline.
_clamp_deadline() {
  local _cap=$(( _work_deadline - _diag_reserve - _oc_overrun_reserve ))
  if (( $1 > _cap )); then printf '%s' "${_cap}"; else printf '%s' "$1"; fi
}

# --- Diagnostics: bounded (last 50 events, <=256KiB, allowlisted fields) ---
# Only classification-shaped fields are printed. Status bodies and event
# messages are API-controlled text: they stay out of the step log and so out
# of the trace copied into artifacts. Sizes are capped as before.
_dump_diagnostics() {
  _api_quiet
  echo ">>> DIAG: Subscription rhacs-operator in ${ACS_NAMESPACE} (allowlisted fields):"
  _diag_get oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
    -o jsonpath='{.metadata.name} channel={.spec.channel} currentCSV={.status.currentCSV} installedCSV={.status.installedCSV}{"\n"}' | head -c 262144 || true
  echo ">>> DIAG: Subscription conditions (type/status/reason only):"
  _diag_get oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} reason={.reason}{"\n"}{end}' | head -50 || true
  echo ">>> DIAG: events in ${ACS_NAMESPACE} (last 50, no messages):"
  _diag_get oc get events -n "${ACS_NAMESPACE}" --sort-by='.lastTimestamp' \
    -o jsonpath='{range .items[*]}{.lastTimestamp} {.type} {.reason} {.involvedObject.kind}/{.involvedObject.name} x{.count}{"\n"}{end}' | tail -50 || true
  echo ">>> DIAG: events in openshift-marketplace (last 50, no messages):"
  _diag_get oc get events -n openshift-marketplace --sort-by='.lastTimestamp' \
    -o jsonpath='{range .items[*]}{.lastTimestamp} {.type} {.reason} {.involvedObject.kind}/{.involvedObject.name} x{.count}{"\n"}{end}' | tail -50 || true
  echo ">>> DIAG: CSVs in ${ACS_NAMESPACE} (name/phase only):"
  _diag_get oc get csv -n "${ACS_NAMESPACE}" \
    -o jsonpath='{range .items[*]}  {.metadata.name} {.status.phase}{"\n"}{end}' | head -50 || true
  _api_loud
}

echo ">>> PHASE: initialization"

ACS_CHANNEL="${ACS_CHANNEL:-stable}"
ACS_INSTALL_TIMEOUT="${ACS_INSTALL_TIMEOUT:-600}"
ACS_CSV_WAIT_TIMEOUT="${ACS_CSV_WAIT_TIMEOUT:-600}"
ACS_NAMESPACE="${ACS_NAMESPACE:-rhacs-operator}"
ACS_REPORT_ONLY="${ACS_REPORT_ONLY:-0}"

# Input validation: namespace (DNS-1123 label), channel name, and
# integer-second timeouts (1..900). Each rejection classifies acs-invalid-input
# and exits 2 before any oc call.
#
# ACS_NAMESPACE is interpolated literally into `oc create namespace`, the
# OperatorGroup manifest, and the CSV label selector
# `operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=`, so a malformed value
# is an input error rather than an API error: unchecked, a bad create surfaces
# as acs-namespace-error and a selector that matches nothing surfaces as "no
# CSV". Apply the DNS-1123 label rule up front: lowercase alphanumerics and
# hyphens, alphanumeric at both ends, at most 63 characters.
if ! [[ "${ACS_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#ACS_NAMESPACE} > 63 )); then
  echo "ERROR: invalid ACS_NAMESPACE '${ACS_NAMESPACE}' (DNS-1123 label: lowercase alphanumerics and hyphens, alphanumeric at both ends, at most 63 characters)"
  _classify "acs-invalid-input" "ACS_NAMESPACE failed validation"
  exit 2
fi
if ! [[ "${ACS_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: invalid ACS_CHANNEL '${ACS_CHANNEL}'"
  _classify "acs-invalid-input" "ACS_CHANNEL failed validation"
  exit 2
fi
for _v in ACS_INSTALL_TIMEOUT ACS_CSV_WAIT_TIMEOUT; do
  _v_raw="${!_v}"
  # Bounded to 9 digits so the 10# conversion below cannot wrap a 64-bit
  # integer into the accepted range.
  if ! [[ "${_v_raw}" =~ ^[0-9]{1,9}$ ]]; then
    echo "ERROR: ${_v} must be integer seconds in 1..900 (got '${_v_raw}')"
    _classify "acs-invalid-input" "${_v} failed validation"
    exit 2
  fi
  # Normalize to decimal and write the value back before any arithmetic
  # sees it. Bash reads a leading-zero literal as OCTAL: "0600" is 384s, so
  # an un-normalized value clears this range check at the wrong magnitude,
  # understates the wait-sum check below (0600 + 0700 evaluates as 832, not
  # 1300), and hands a wrong number to both phase deadlines and to every log
  # line. "0900" is worse: (( 0900 )) aborts the script with exit 1 and no
  # classification. The 10# conversion makes the range check, the wait-sum
  # check, both phase deadlines, and the log interpolations all read the
  # decimal seconds the operator wrote.
  printf -v "${_v}" '%d' "$(( 10#${_v_raw} ))"
  if (( ${!_v} < 1 || ${!_v} > 900 )); then
    echo "ERROR: ${_v} must be integer seconds in 1..900 (got '${_v_raw}')"
    _classify "acs-invalid-input" "${_v} failed validation"
    exit 2
  fi
done

# Budget invariant (ref.yaml: timeout 30m (1800s) − grace 150s = 1650s
# work; overhead 180s + precondition ≤120s + diagnostics ≤120s): the two
# waits are sequential and each independently bounded, so the SUM must
# multiply out: per-variable 1..900 alone admits 900s + 900s = 1800s of
# waits, overrunning the budget so TERM records StepTerminated instead
# of the acs-csv-timeout classification. This check is the fail-fast half
# of the contract (reject absurd configs with exit 2); the runtime half is
# _work_deadline above, which charges elapsed setup and caps both phase
# deadlines so the arithmetic holds regardless of setup slowness or an
# in-flight oc request that finishes after a poll deadline.
if (( ACS_CSV_WAIT_TIMEOUT + ACS_INSTALL_TIMEOUT > 1230 )); then
  echo "ERROR: ACS_CSV_WAIT_TIMEOUT + ACS_INSTALL_TIMEOUT must be ≤ 1230s (work budget 1650s − overhead 180s − precondition 120s − diagnostics 120s); got $((ACS_CSV_WAIT_TIMEOUT + ACS_INSTALL_TIMEOUT))s"
  _classify "acs-invalid-input" "wait sum ${ACS_CSV_WAIT_TIMEOUT}s + ${ACS_INSTALL_TIMEOUT}s exceeds the step work budget"
  exit 2
fi

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
  # packagemanifest precondition on purpose: detection must work when the
  # catalog is absent or erroring. It also runs before the self-disable
  # check so the full property set is recorded even when an OperatorPolicy
  # owns the install. Subscription presence is queried independently of
  # spec.channel (OLM permits an omitted channel). The named reads carry
  # --ignore-not-found, so a missing object stays a determinate absence. A
  # read that fails for any other reason is kept as its own state
  # (undecided) instead of being folded into the absent/adopted answer:
  # detection output must not report an API or RBAC error as an object state.
  _api_quiet
  _subname=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" --ignore-not-found -o jsonpath='{.metadata.name}' 2>/dev/null) || _subname="undecided"
  _sub=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" --ignore-not-found -o jsonpath='{.spec.channel}' 2>/dev/null) || _sub="undecided"
  _csvp=$(oc get csv -n "${ACS_NAMESPACE}" -l "operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) || _csvp="undecided"
  _pm=$(oc get packagemanifest rhacs-operator -n openshift-marketplace --ignore-not-found -o name 2>/dev/null) || _pm="undecided"
  if [[ "${_subname}" == "undecided" ]]; then
    _subname_state="undecided"
  elif [[ -n "${_subname}" ]]; then
    _subname_state="adopted"
  else
    _subname_state="absent"
  fi
  if [[ "${_pm}" == "undecided" ]]; then
    _pm_state="undecided"
  elif [[ -n "${_pm}" ]]; then
    _pm_state="present"
  else
    _pm_state="absent"
  fi
  _prop "report_only" "true"
  _prop "acs_subscription" "${_subname_state}"
  _prop "channel_observed" "$([[ "${_subname_state}" == "adopted" ]] && echo "${_sub:-empty}" || echo "${_subname_state}")"
  _prop "csv_phase" "${_csvp:-absent}"
  _prop "packagemanifest" "${_pm:-absent}"
  echo ">>> REPORT_ONLY: subscription=${_sub:-absent} csv=${_csvp:-absent} packagemanifest=${_pm_state}"
  _api_loud
  exit 0
fi

# --- Self-disable: if the OperatorPolicy already owns a healthy install,
#     the workaround is redundant - report and exit 0 without installing.
#     The CRD lookup gates this whole block, so only a NotFound answer means
#     "no OperatorPolicy CRD on this cluster": a Forbidden, timeout, or
#     transport error would skip the ownership check entirely and report
#     workaround_removal_ready=false for an install the policy owns. Keep the
#     exit status, retry, and fail closed, the same convention the list query
#     below uses.
_api_quiet
_op_crd_state="undecided"
_op_crd_out=""
for _crd_attempt in 1 2 3; do
  if _op_crd_out=$(oc get crd operatorpolicies.policy.open-cluster-management.io 2>&1); then
    _op_crd_state="present"
    break
  fi
  if [[ "${_op_crd_out}" == *"Error from server (NotFound)"* ]]; then
    _op_crd_state="absent"
    break
  fi
  (( _crd_attempt < 3 )) || break
  sleep 5
done
_prop "operatorpolicy_crd" "${_op_crd_state}"
if [[ "${_op_crd_state}" == "undecided" ]]; then
  _classify "acs-operatorpolicy-query-failed" "operatorpolicy CRD lookup failed after 3 attempts ($(_api_err_class "${_op_crd_out}")); self-disable undecidable, not installing"
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
if [[ "${_op_crd_state}" == "present" ]]; then
  # A FAILED cluster-wide list is not "no policy": the list decides whether a
  # live OperatorPolicy owns this install, so an RBAC, timeout or transport
  # error collapsing to empty output would let the step skip the self-disable
  # decision and install a second Subscription for an operator the policy
  # already owns. Keep the exit status, retry, and fail closed, the same
  # convention the OperatorGroup query below uses. A NotFound answer (the CRD
  # is registered but the API no longer serves the resource) is a real
  # absence: no policy of that kind can exist, so the install path runs.
  _op_query_ok=false
  _op_status=""
  for _op_attempt in 1 2 3; do
    # Fully-qualified group and kind, the form the CRD probe above uses: a bare
    # kind resolves by name alone, so any other registered group serving an
    # OperatorPolicy would answer for this one.
    if _op_status=$(oc get operatorpolicies.policy.open-cluster-management.io -A -o json 2>&1); then
      _op_query_ok=true
      break
    fi
    (( _op_attempt < 3 )) || break
    sleep 5
  done
  if [[ "${_op_query_ok}" != "true" ]]; then
    if [[ "${_op_status}" == *"Error from server (NotFound)"* ]]; then
      _prop "operatorpolicy_query" "not-found"
      _op_status=""
    else
      _classify "acs-operatorpolicy-query-failed" "operatorpolicy list failed cluster-wide after 3 attempts ($(_api_err_class "${_op_status}")); self-disable undecidable, not installing"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  fi
  if [[ -n "${_op_status}" ]]; then
    _self_disable=$(printf '%s' "${_op_status}" | python3 -c '
import json, sys
requested = sys.argv[1] if len(sys.argv) > 1 else ""
target_ns = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    d = json.load(sys.stdin)
    items = d.get("items", [d])
    # OperatorPolicy is namespaced and the list above is cluster-wide, so the
    # name alone does not identify the policy that owns this install. Bind the
    # match to spec.subscription.namespace, the namespace this step manages.
    # The OperatorPolicy controller defaults an omitted subscription namespace
    # to the namespace the policy itself lives in, so a strict equality test
    # would miss a policy that omits the field and install a second
    # Subscription for an operator that policy already owns. Compare against
    # the effective target.
    def effective_ns(item):
        sub = item.get("spec", {}).get("subscription", {}) or {}
        return sub.get("namespace") or item.get("metadata", {}).get("namespace")
    matches = [i for i in items
               if i.get("metadata", {}).get("name") == "operatorpolicy-rhacs-operator"
               and effective_ns(i) == target_ns]
    if not matches:
        # No policy owns this namespace: the install path runs.
        print("false")
    elif len(matches) > 1:
        # Ambiguous: several same-named policies claim this namespace. Fail
        # closed, never claim the workaround is removable.
        print("ambiguous")
    else:
        i = matches[0]
        conds = i.get("status", {}).get("conditions", [])
        compliant = any(c.get("type") == "Compliant" and c.get("status") == "True" for c in conds)
        spec_ch = (i.get("spec", {}).get("subscription", {}) or {}).get("channel")
        # Self-disable only on a matching channel: an adopted Subscription on a
        # different channel is not workaround-removal ready, so report the
        # observed channel and let the install path record the mismatch.
        out = "false"
        if compliant and spec_ch:
            out = "true" if spec_ch == requested else "withheld " + spec_ch
        print(out)
except Exception:
    print("false")
' "${ACS_CHANNEL}" "${ACS_NAMESPACE}" 2>/dev/null || echo "false")
    if [[ "${_self_disable}" == "true" ]]; then
      # A Compliant policy says the policy is satisfied; it does not name the
      # CSV the operator is progressing to. Selecting the first CSV that
      # carries the rhacs-operator label answers with whichever name the API
      # lists first, so during an upgrade that can be an older CSV still in
      # Succeeded phase while status.currentCSV points at one that is Pending
      # or Failed, and the step would claim workaround_removal_ready and exit
      # 0 on an operator that is not up. Name the CSV the way the wait below
      # does, from status.currentCSV, and require that CSV to be Succeeded.
      # An empty or unreadable name withholds the self-disable instead of
      # claiming readiness: the install path adopts the existing Subscription
      # (it never creates over one) and the CSV wait classifies the outcome.
      _sd_csv=""
      _existing_csv=""
      if _sd_csv=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null) && [[ -n "${_sd_csv}" ]]; then
        _existing_csv=$(oc get csv "${_sd_csv}" -n "${ACS_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null) || _existing_csv=""
      fi
      if [[ "${_existing_csv}" == "Succeeded" ]]; then
        echo ">>> workaround_removal_ready=true (OperatorPolicy Compliant, current CSV ${_sd_csv} Succeeded) - not installing"
        _prop "workaround_removal_ready" "true"
        _prop "acs_subscription" "adopted"
        _prop "csv_name" "${_sd_csv}"
        _prop "csv_phase" "Succeeded"
        exit 0
      fi
      echo ">>> NOTE: OperatorPolicy Compliant, but current CSV '${_existing_csv:-unresolved}' (Subscription currentCSV '${_sd_csv:-empty}') is not Succeeded: self-disable withheld, installing"
      _prop "csv_self_disable_withheld" "${_existing_csv:-unresolved}"
    elif [[ "${_self_disable}" == "ambiguous" ]]; then
      echo ">>> NOTE: more than one OperatorPolicy claims subscription namespace ${ACS_NAMESPACE}: self-disable withheld, installing"
      _prop "operatorpolicy_match" "ambiguous"
    elif [[ "${_self_disable}" == withheld* ]]; then
      _policy_ch="${_self_disable#withheld }"
      echo ">>> NOTE: OperatorPolicy channel '${_policy_ch}' != requested '${ACS_CHANNEL}': self-disable withheld, installing"
      _prop "channel_self_disable_withheld" "${_policy_ch}!=${ACS_CHANNEL}"
    fi
  fi
fi
_api_loud
_prop "workaround_removal_ready" "false"

# --- Subscription state, resolved BEFORE the catalog precondition.
#     Adoption decides whether the requested channel has to exist. An
#     existing Subscription is never created or overwritten here, so its
#     pinned channel governs that install and ACS_CHANNEL is irrelevant to
#     it. Resolving the Subscription first keeps an adopted Subscription on
#     a channel the current catalog listing no longer offers from failing as
#     acs-catalog-missing before adoption is considered.
#     The probe keeps three states, present/absent/undecided, the same
#     convention the OperatorPolicy CRD lookup and list use: only the API
#     server's NotFound shape means absence, and any other error is retried
#     (5s, then 15s) before it settles as undecided. A failed probe is NOT
#     absence: reading one as absent let a Forbidden, a transport error, or a
#     bare "command not found" combine with an unavailable catalog into
#     acs-catalog-missing / acs-catalog-query-failed on a cluster whose
#     Subscription exists and which the adoption path permits. When the
#     listing is usable, undecided is left to the create-if-absent adoption
#     net below (the create re-checks and adopts on AlreadyExists) exactly as
#     an absent answer was. Only the conjunction of an undecided probe and an
#     unavailable listing classifies, as acs-subscription-query-failed: the
#     probe never answered, so neither a missing nor an erroring catalog can
#     be reported as the reason a Subscription is not being adopted.
#     The probe captures stderr, so it runs under the same quiet scope as
#     every other API-response block: set -x would otherwise trace the
#     expanded value into the xtrace log that _opp_cleanup copies to the
#     artifacts.
_sub_state="undecided"
_sub_existing_channel=""
_sub_probe=""
_api_quiet
for _sub_attempt in 1 2 3; do
  if _sub_probe=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>&1); then
    _sub_state="present"
    _sub_existing_channel="${_sub_probe}"
    break
  fi
  # The same shape test the sibling probes use: a missing helper or a wrapper
  # message carrying the phrase is a broken capture path, not an API answer.
  if [[ "${_sub_probe}" == *"Error from server (NotFound)"* ]]; then
    _sub_state="absent"
    break
  fi
  # No sleep after the last attempt: there is no retry left to use it.
  if (( _sub_attempt >= 3 )); then
    echo ">>> subscription probe failed (attempt ${_sub_attempt}/3), no attempts left: $(_api_err_class "${_sub_probe}")"
    break
  fi
  _sub_backoff=$(( _sub_attempt == 1 ? 5 : 15 ))
  echo ">>> subscription probe failed (attempt ${_sub_attempt}/3), retrying in ${_sub_backoff}s: $(_api_err_class "${_sub_probe}")"
  sleep "${_sub_backoff}"
done
_api_loud
_prop "subscription_probe" "${_sub_state}"

# --- Fail-fast precondition: packagemanifest must exist, and the channel this
#     step would create a Subscription on must be listed. Three-way classify
#     with bounded retry; a query error is NEVER classified as catalog-missing.
#     The precondition is a property of the CREATE path. An adopted
#     Subscription already exists, so the current catalog listing decides
#     nothing about it: a missing packagemanifest or a failed query is recorded
#     as catalog_precondition and the CSV wait plus the Subscription conditions
#     classify the outcome. Gating adoption here failed a healthy Succeeded
#     CSV whenever the catalog listing was down or slow to populate.
_precondition_ok=false
_pm_raw=""
_pm_notfound=false
_api_quiet
for _attempt in 1 2 3; do
  if _pm_raw=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>&1); then
    _precondition_ok=true
    break
  fi
  # Only the API server's NotFound error shape means absence, the same test
  # the OperatorPolicy queries use. A substring test on "not found" also
  # matches a missing helper (a bare "command not found") or a wrapper
  # message carrying the phrase, which would read as a missing packagemanifest
  # and make the "(successful query)" detail below false. The shape test also
  # needs no pipe over this payload (a full packagemanifest JSON), so a
  # producer still writing when the test answers cannot take SIGPIPE.
  if [[ "${_pm_raw}" == *"Error from server (NotFound)"* ]]; then
    _pm_notfound=true
    break
  fi
  # No sleep after the last attempt: there is no retry left to use it, and
  # the 30s came straight out of the shared work budget on the path that was
  # already failing. The sibling OperatorGroup ladder ends the same way.
  if (( _attempt >= 3 )); then
    echo ">>> precondition query failed (attempt ${_attempt}/3), no attempts left: $(_api_err_class "${_pm_raw}")"
    break
  fi
  _backoff=$(( _attempt == 1 ? 5 : 15 ))
  echo ">>> precondition query failed (attempt ${_attempt}/3), retrying in ${_backoff}s: $(_api_err_class "${_pm_raw}")"
  sleep "${_backoff}"
done
_catalog_listing=false
if [[ "${_precondition_ok}" == "true" ]]; then
  _catalog_listing=true
elif [[ "${_sub_state}" == "present" ]]; then
  if [[ "${_pm_notfound}" == "true" ]]; then
    _prop "catalog_precondition" "missing-adopted"
    echo ">>> NOTE: packagemanifest rhacs-operator not found in openshift-marketplace; Subscription rhacs-operator already exists - not gating adoption on the catalog listing"
  else
    _prop "catalog_precondition" "query-failed-adopted"
    echo ">>> NOTE: packagemanifest query failed after 3 attempts ($(_api_err_class "${_pm_raw}")); Subscription rhacs-operator already exists - not gating adoption on the catalog listing"
  fi
elif [[ "${_sub_state}" == "undecided" ]]; then
  # Both answers are unknown at once: the probe never answered and the catalog
  # listing is unavailable. A Subscription may exist, so neither a missing nor
  # an erroring catalog may be reported in its place; the probe's own failure
  # is the classification and the catalog outcome is a class in the detail.
  _classify "acs-subscription-query-failed" "subscription rhacs-operator probe errored after 3 attempts ($(_api_err_class "${_sub_probe}")) with the catalog listing also unavailable ($(_api_err_class "${_pm_raw}"))"
  echo "ERROR: ${_class_detail}"
  exit 1
elif [[ "${_pm_notfound}" == "true" ]]; then
  _classify "acs-catalog-missing" "packagemanifest rhacs-operator not found in openshift-marketplace (successful query)"
  echo "ERROR: ${_class_detail}"
  exit 1
else
  _classify "acs-catalog-query-failed" "packagemanifest query errored after 3 attempts (non-reverting class: $(_api_err_class "${_pm_raw}"))"
  echo "ERROR: ${_class_detail}"
  exit 1
fi
# One parse answers two membership questions: is the REQUESTED channel still
# listed (the channel a fresh Subscription would be created on), and is the
# ADOPTED Subscription's channel still listed ("na" when there is no
# Subscription or it omits spec.channel). Both answers are needed because the
# requested channel is only a requirement for the create path.
_channel_ok=$(printf '%s' "${_pm_raw}" | python3 -c '
import json, sys
try:
    requested = sys.argv[1]
    observed = sys.argv[2] if len(sys.argv) > 2 else ""
    d = json.load(sys.stdin)
    chans = d.get("status", {}).get("channels", [])
    names = [c.get("name") for c in chans]
    head = next((c.get("currentCSV") for c in chans if c.get("name") == requested), None)
    req = "listed" if requested in names else "unlisted"
    if not observed:
        obs = "na"
    else:
        obs = "listed" if observed in names else "unlisted"
    print(" ".join(["parsed", req, obs, str(head), ",".join(names[:8])]))
except Exception:
    print("error")
' "${ACS_CHANNEL}" "${_sub_existing_channel}" 2>/dev/null || echo "error")
read -r _chk _req_listed _obs_listed _req_head _chk_names <<<"${_channel_ok}"
# The helper prints "parsed" first: a parse error, an empty answer, or a helper
# that did not run all land here as a listing that is not usable. On the create
# path that is a hard failure; an adopted Subscription has no listing to
# consult, so the note above already recorded why and the wait classifies.
if [[ "${_chk}" != "parsed" ]]; then
  if [[ "${_catalog_listing}" == "true" ]]; then
    _classify "acs-catalog-query-failed" "packagemanifest channel listing unparseable (query succeeded but returned non-JSON)"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
  _chk_names=""
fi
if [[ "${_req_listed}" == "unlisted" ]]; then
  if [[ "${_sub_state}" == "present" ]]; then
    # Adopted: this step creates nothing, so the requested channel does not
    # have to be offered by the current listing. Record it and keep going.
    echo ">>> NOTE: channel '${ACS_CHANNEL}' not listed for rhacs-operator (${_chk_names}); Subscription rhacs-operator already exists with channel '${_sub_existing_channel:-empty}', adopting, not creating"
    _prop "channel_requested_unlisted" "${ACS_CHANNEL}"
  else
    _classify "acs-catalog-missing" "channel '${ACS_CHANNEL}' not listed for rhacs-operator ($(printf '%s' "${_chk_names}" | head -c 160))"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
fi
if [[ "${_obs_listed}" == "unlisted" ]]; then
  # The adopted Subscription's own channel is gone from the listing (renamed
  # or dropped by a newer catalog). That is a condition of the adopted
  # Subscription, not a missing catalog: the Subscription stays pinned as
  # found, and the CSV wait plus the Subscription-condition classification
  # below decide the outcome.
  echo ">>> NOTE: adopted Subscription channel '${_sub_existing_channel}' not listed for rhacs-operator (${_chk_names}); left untouched, the CSV wait classifies the outcome"
  _prop "channel_delisted" "${_sub_existing_channel}"
fi
if [[ "${_sub_state}" == "present" ]]; then
  if [[ "${_catalog_listing}" == "true" ]]; then
    echo ">>> precondition: rhacs-operator present; adopted Subscription channel '${_sub_existing_channel:-empty}' (requested ${ACS_CHANNEL}, head: ${_req_head})"
  else
    echo ">>> precondition: catalog listing unavailable; adopting Subscription rhacs-operator on channel '${_sub_existing_channel:-empty}' (requested ${ACS_CHANNEL})"
  fi
else
  echo ">>> precondition: rhacs-operator present; channel ${ACS_CHANNEL} head: ${_req_head}"
fi
_api_loud



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
#     second group in one namespace puts CSVs into TooManyOperatorGroups).
#     A FAILED list is not an EMPTY list: an oc error collapsing to empty
#     output sends a differently named existing group down the create path
#     and installs the second group this check exists to prevent. The query
#     keeps its exit status, retries, and classifies rather than guessing.
_og_names() {
  oc get operatorgroups.operators.coreos.com -n "${ACS_NAMESPACE}" -o name 2>&1
}
# oc create, not apply: an apply over a same-named object another writer
# created between the list and this call would modify it (this manifest's
# spec: {} drops a targetNamespaces the other writer set), which breaks the
# adoption contract - an object this step did not create is never written.
_og_create() {
  # CIOP-1: marshal with jq --arg. Shell interpolation into YAML breaks on a
  # quote or colon in the value and no parser gets to check the result.
  jq -cn --arg ns "${ACS_NAMESPACE}" \
    '{apiVersion:"operators.coreos.com/v1",
      kind:"OperatorGroup",
      metadata:{name:"rhacs-operator-group",namespace:$ns},
      spec:{}}' |
  oc create -f - 2>&1
}
# Used only on the success path of _og_create, where rhacs-operator-group is
# this step's own object: a second group that appeared concurrently is
# reconciled by removing THIS step's group and adopting the other writer's,
# never by touching an object this step did not create.
_og_delete_own() {
  oc delete operatorgroups.operators.coreos.com rhacs-operator-group -n "${ACS_NAMESPACE}" 2>&1
}
_api_quiet
_og_query_ok=false
_og_listed=""
for _og_attempt in 1 2 3; do
  if _og_listed=$(_og_names); then
    _og_query_ok=true
    break
  fi
  (( _og_attempt < 3 )) || break
  sleep 5
done
if [[ "${_og_query_ok}" != "true" ]]; then
  _classify "acs-operatorgroup-error" "operatorgroups query failed in ${ACS_NAMESPACE} after 3 attempts ($(_api_err_class "${_og_listed}"))"
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
_og_objects=$(printf '%s\n' "${_og_listed}" | grep '^operatorgroup' || true)
if [[ -n "${_og_objects}" ]]; then
  _prop "acs_operatorgroup" "adopted"
  _og_count=$(printf '%s\n' "${_og_objects}" | grep -c . || true)
  if (( _og_count > 1 )); then
    _prop "acs_operatorgroup_count" "${_og_count}"
  fi
else
  if _og_out=$(_og_create); then
    _prop "acs_operatorgroup" "created"
    # A DIFFERENTLY named group can appear in the same window: the caller's
    # list could not see it and this create cannot collide with it, so without
    # a second look two groups would stay in the namespace and every CSV in it
    # would sit in TooManyOperatorGroups. One re-list settles it.
    _og_after=""
    if _og_after=$(_og_names); then
      _og_after_objs=$(printf '%s\n' "${_og_after}" | grep '^operatorgroup' || true)
      _og_after_count=$(printf '%s\n' "${_og_after_objs}" | grep -c . || true)
      if (( _og_after_count > 1 )); then
        _prop "acs_operatorgroup_count" "${_og_after_count}"
        if _og_del_out=$(_og_delete_own); then
          _prop "acs_operatorgroup" "adopted-concurrent"
          echo ">>> NOTE: ${_og_after_count} OperatorGroups appeared concurrently - removed this step's rhacs-operator-group, adopting the other writer's group"
        else
          _prop "acs_operatorgroup_reconcile" "delete-failed"
          echo ">>> NOTE: ${_og_after_count} OperatorGroups appeared concurrently and this step's rhacs-operator-group could not be removed ($(_api_err_class "${_og_del_out}")); the CSV wait classifies the outcome"
        fi
      fi
    else
      _prop "acs_operatorgroup_reconcile" "query-failed"
    fi
  else
    # Re-list on create failure: a live OperatorPolicy (or any other writer)
    # can create the group between the list and this create. Adopt whatever is
    # there now; classify only when nothing was created.
    _og_relist=""
    _og_relist_ok=false
    if _og_relist=$(_og_names); then _og_relist_ok=true; fi
    _og_relist_objs=""
    if [[ "${_og_relist_ok}" == "true" ]]; then
      _og_relist_objs=$(printf '%s\n' "${_og_relist}" | grep '^operatorgroup' || true)
    fi
    if [[ -n "${_og_relist_objs}" ]]; then
      _prop "acs_operatorgroup" "race-tolerated"
      _og_relist_count=$(printf '%s\n' "${_og_relist_objs}" | grep -c . || true)
      if (( _og_relist_count > 1 )); then
        # Another writer's object, so it is never removed here: record and let
        # the CSV wait classify the TooManyOperatorGroups outcome.
        _prop "acs_operatorgroup_count" "${_og_relist_count}"
      fi
      echo ">>> NOTE: OperatorGroup created concurrently by another writer - adopting"
    else
      _classify "acs-operatorgroup-error" "failed to create OperatorGroup rhacs-operator-group in ${ACS_NAMESPACE} ($(_api_err_class "${_og_out}"))"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  fi
fi
_api_loud

# --- Create-if-absent: Subscription (never apply over an existing one) ---
_prop "channel_requested" "${ACS_CHANNEL}"
if oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" >/dev/null 2>&1; then
  _existing_ch=$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null) || _existing_ch="unknown"
  _prop "acs_subscription" "adopted"
  _prop "channel_observed" "${_existing_ch}"
  if [[ "${_existing_ch}" != "${ACS_CHANNEL}" ]]; then
    echo ">>> NOTE: existing Subscription channel '${_existing_ch}' != requested '${ACS_CHANNEL}' - adopting, not overwriting (a live OperatorPolicy is the owner)"
    _prop "channel_mismatch" "${_existing_ch}!=${ACS_CHANNEL}"
  fi
else
  # oc create (not apply): if a second writer (a live OperatorPolicy) wins
  # the race, create fails AlreadyExists and we adopt, never overwrite.
  # CIOP-1: jq --arg marshalling (see _og_create): the channel string is a
  # variable, so it never reaches the manifest as raw text.
  if ! jq -cn --arg ns "${ACS_NAMESPACE}" --arg ch "${ACS_CHANNEL}" \
      '{apiVersion:"operators.coreos.com/v1alpha1",
        kind:"Subscription",
        metadata:{name:"rhacs-operator",namespace:$ns},
        spec:{channel:$ch,
              installPlanApproval:"Automatic",
              name:"rhacs-operator",
              source:"redhat-operators",
              sourceNamespace:"openshift-marketplace"}}' |
      oc create -f - 2>&1
  then
    if oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" >/dev/null 2>&1; then
      _prop "acs_subscription" "race-tolerated"
      _prop "channel_observed" "$(oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo unknown)"
      echo ">>> NOTE: Subscription created concurrently by another writer: adopting"
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
#     Deadline is ELAPSED time, not a sleep counter: a slow-but-successful
#     response (each oc call carries --request-timeout=20s) must be
#     charged against the budget, or the real wait overruns
#     ACS_CSV_WAIT_TIMEOUT and breaks the multiply-out budget recorded in
#     the step ref.yaml.
echo ">>> PHASE: Waiting for ACS operator CSV (timeout: ${ACS_CSV_WAIT_TIMEOUT}s)"
typeset csvName=""
typeset -i query_failures=0
typeset -i csv_start csv_budget csv_deadline csv_now csv_left csv_diag_at
typeset -i csv_elapsed=0
typeset _csv_clamp_note=""
csv_start=$(date +%s)
_csv_want=$(( csv_start + ACS_CSV_WAIT_TIMEOUT ))
csv_deadline=$(_clamp_deadline "${_csv_want}")
csv_budget=$(( csv_deadline - csv_start ))
if (( csv_deadline < _csv_want )); then
  _csv_clamp_note=" (requested ${ACS_CSV_WAIT_TIMEOUT}s, clamped by the shared ${_work_budget}s work budget)"
  echo ">>> NOTE: CSV-name wait clamped to ${csv_budget}s (requested ${ACS_CSV_WAIT_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
# Elapsed time is measured from the phase start recorded above. Deriving it as
# the requested timeout minus the remaining time measures against the CLAMPED
# deadline instead, so a clamped wait reported the seconds the phase asked for
# rather than the seconds it had been running (a 35s clamped wait read 55s).
csv_diag_at=$(( csv_start + 30 ))
while [[ -z "${csvName}" ]]; do
    csv_now=$(date +%s)
    csv_left=$(( csv_deadline - csv_now ))
    csv_elapsed=$(( csv_now - csv_start ))
    if (( csv_left <= 0 )); then break; fi
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
        # Periodic condition diagnostics every 30s of elapsed time.
        if (( csv_now >= csv_diag_at )); then
            _api_quiet
            echo ">>> CSV poll: waited ${csv_elapsed}s of ${csv_budget}s${_csv_clamp_note}; Subscription conditions:"
            oc get subscription.operators.coreos.com rhacs-operator -n "${ACS_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}  {.type}={.status} reason={.reason}{"\n"}{end}' 2>/dev/null || true
            _api_loud
            csv_diag_at=$(( $(date +%s) + 30 ))
        fi
        # Never sleep past the deadline.
        csv_left=$(( csv_deadline - $(date +%s) ))
        if (( csv_left <= 0 )); then break; fi
        if (( csv_left < 10 )); then sleep "${csv_left}"; else sleep 10; fi
    fi
done

if [[ -z "${csvName}" ]]; then
    # Classify from Subscription conditions before defaulting to timeout.
    _cond_classify
    if [[ -n "${_cond_class}" ]]; then
      _classify "${_cond_class}" "${_cond_detail}"
    else
      _classify "acs-csv-timeout" "no currentCSV after ${ACS_CSV_WAIT_TIMEOUT}s (no classified condition; see DIAG)"
    fi
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
fi

: "CSV: ${csvName}"
_prop "csv_name" "${csvName}"

# --- Wait for CSV Succeeded. status.currentCSV is the CSV the Subscription
#     is progressing TO: OLM publishes the name at InstallPlan resolution,
#     before the InstallPlan executor creates the CSV object. `oc wait`
#     aborts immediately on a missing named resource (IsNotFound is only
#     ignored for --for=delete/--for=create), so waiting directly on a
#     not-yet-created CSV records acs-csv-timeout at t~0 with phase
#     unknown. Poll for existence first, then wait for the phase, both
#     inside the single ACS_INSTALL_TIMEOUT budget.
typeset -i install_deadline install_left
typeset csv_probe_out=""
_install_want=$(( $(date +%s) + ACS_INSTALL_TIMEOUT ))
install_deadline=$(_clamp_deadline "${_install_want}")
if (( install_deadline < _install_want )); then
  echo ">>> NOTE: CSV-Succeeded wait clamped to $(( install_deadline - $(date +%s) ))s (requested ${ACS_INSTALL_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
# Two-stage wait (L-1): stage 1 is `oc wait --for=create`, which blocks on
# the API server for the object itself instead of polling it with `oc get`
# plus `sleep` (each poll burns the shared work budget). Stage 2 waits for
# the phase on the object stage 1 saw. `--timeout=0s` means check once and
# return, so an exhausted budget still classifies rather than hanging.
typeset -i _csv_created=0
_api_quiet
install_left=$(( install_deadline - $(date +%s) ))
(( install_left < 0 )) && install_left=0
if oc wait csv "${csvName}" -n "${ACS_NAMESPACE}" \
    --for=create --timeout="${install_left}s" 2>&1; then
    _csv_created=1
    csv_probe_out=""
else
    # One bounded probe carries the API error text the NotFound test below
    # reads, so "never created" is classified from the API answer, never
    # guessed. An object that appeared after the create wait timed out still
    # gets stage 2 (the probe succeeded, so there is something to wait on).
    if csv_probe_out=$(oc get csv "${csvName}" -n "${ACS_NAMESPACE}" -o name 2>&1); then
        _csv_created=1
    fi
fi
_api_loud
install_left=$(( install_deadline - $(date +%s) ))
(( install_left < 0 )) && install_left=0

if (( ! _csv_created )) || ! oc wait csv "${csvName}" -n "${ACS_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout="${install_left}s" 2>&1; then
    _phase=$(oc get csv "${csvName}" -n "${ACS_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null) || _phase="unknown"
    _probe_notfound=0
    _api_quiet
    # Same shape test as the precondition: a missing helper or a wrapper
    # message carrying "not found" is a failed probe, not an absent CSV, so
    # only the API server's NotFound answer selects the "never created"
    # detail. No pipe over the probe error (it can be a full API error body).
    if [[ "${csv_probe_out}" == *"Error from server (NotFound)"* ]]; then _probe_notfound=1; fi
    _api_loud
    # Precedence: a classified Subscription condition outranks the CSV phase and
    # the deadline, exactly as the no-currentCSV branch above applies it. An
    # InstallPlan that fails after status.currentCSV is published never creates
    # the named CSV, so reporting acs-csv-timeout there would attribute the
    # failure to the deadline instead of the InstallPlan.
    _cond_classify
    if [[ -n "${_cond_class}" ]]; then
      _classify "${_cond_class}" "${_cond_detail} (CSV ${csvName}, phase ${_phase})"
    elif [[ "${_phase}" == "Failed" ]]; then
      _classify "acs-csv-failed" "CSV ${csvName} reached phase Failed"
    elif [[ "${_phase}" == "unknown" ]] && (( _probe_notfound )); then
      _classify "acs-csv-timeout" "CSV object ${csvName} never created within ${ACS_INSTALL_TIMEOUT}s (currentCSV published, object absent)"
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
