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
#     matching channel, the live quay-operator Subscription runs that same
#     channel (an unreadable/absent Subscription is unknown and does not block
#     the self-disable on its own), the CSV is Succeeded AND the existing
#     QuayRegistry is Available, emit workaround_removal_ready=true and exit 0.
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
    "${_xtrace_log}" || true
  if [[ ${_exit_code} -ne 0 && -n "${ARTIFACT_DIR:-}" ]]; then
    cp "${_xtrace_log}" "${ARTIFACT_DIR}/" || true
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
#   _oc_overrun_reserve  one in-flight state read at a phase deadline, which
#                        retries three times (3 x 20s + 2s = 62s); oc's
#                        --request-timeout bounds each HTTP request, so discovery
#                        plus the resource request can exceed one timeout, which
#                        this reserve absorbs instead of the deadline
#   _verify_reserve      post-Job Secret re-read plus the 160s the registry
#                        check needs at its own start, kept out of the Job wait;
#                        the re-read retries each of the four Secrets up to three
#                        times (4 x (3 x 20s + 2s) = 248s)
_work_budget=2550
_diag_reserve=120
_oc_overrun_reserve=65
_verify_reserve=410
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

# _left_budget <max-seconds>: cap one request's own timeout at the work time
# left after the diagnostics reserve, so the post-Job verification cannot push
# classification past the shared deadline. Prints at least 1.
_left_budget() {
  local _left=$(( _work_deadline - _diag_reserve - $(date +%s) )) _max=$1
  if (( _left < 1 )); then _left=1; fi
  if (( _left < _max )); then _max=${_left}; fi
  printf '%s' "${_max}"
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
  mkdir -p "$(dirname "${_jfile}")" || true
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
    mkdir -p "${SHARED_DIR}/junit" || true
    cp "${_jfile}" "${SHARED_DIR}/junit/" || true
  fi
  # Post-condition: tests>=1 and exit!=0 implies >=1 failure/error.
  local _counts
  _counts=$(python3 - "${_jfile}" <<'PYEOF' || echo "0 0 0"
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
# An object that does not exist yet ("(NotFound)") is absence, not an API
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
      if grep -qF '(NotFound)' <<<"${_out}"; then
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
# --- Environment (step-declared; ref.yaml is the single default authority) ---
: "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL:?}"
: "${INTEROP__OPP__QUAY__NAMESPACE:?}"
: "${INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT:?}"
: "${INTEROP__OPP__QUAY__INSTALL_TIMEOUT:?}"
: "${INTEROP__OPP__QUAY__REGISTRY_TIMEOUT:?}"
: "${INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT:?}"
: "${INTEROP__OPP__QUAY__REPORT_ONLY:?}"

# Input validation: channel name and integer-second timeouts.
if ! [[ "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: invalid INTEROP__OPP__QUAY__OPERATOR_CHANNEL '${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}'"
  _classify "quay-invalid-input" "INTEROP__OPP__QUAY__OPERATOR_CHANNEL failed validation"
  exit 2
fi
for _v in INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT INTEROP__OPP__QUAY__INSTALL_TIMEOUT INTEROP__OPP__QUAY__REGISTRY_TIMEOUT INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT; do
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
if [[ "${INTEROP__OPP__QUAY__NAMESPACE}" != "local-quay" ]]; then
  echo "ERROR: INTEROP__OPP__QUAY__NAMESPACE must be local-quay (got '${INTEROP__OPP__QUAY__NAMESPACE}'); the ported create-admin-user Job hardcodes it"
  _classify "quay-invalid-input" "INTEROP__OPP__QUAY__NAMESPACE '${INTEROP__OPP__QUAY__NAMESPACE}' != local-quay (step and ported Job must act on one namespace)"
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
_phase_sum=$(( INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT + INTEROP__OPP__QUAY__INSTALL_TIMEOUT + INTEROP__OPP__QUAY__REGISTRY_TIMEOUT + INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT ))
if (( _phase_sum > 2130 )); then
  echo "ERROR: phase waits sum to ${_phase_sum}s, must be <= 2130s (work budget 2550s - overhead 180s - precondition 120s - diagnostics 120s)"
  _classify "quay-invalid-input" "phase wait sum ${_phase_sum}s exceeds the step work budget"
  exit 2
fi

echo ">>> PHASE: deploy Quay (channel: ${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}, namespace: ${INTEROP__OPP__QUAY__NAMESPACE}, CSV name wait: ${INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT}s, CSV wait: ${INTEROP__OPP__QUAY__INSTALL_TIMEOUT}s, registry wait: ${INTEROP__OPP__QUAY__REGISTRY_TIMEOUT}s, admin job wait: ${INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT}s)"

# --- Diagnostics: bounded (last 50 events, <=256KiB/object) ---
_dump_diagnostics() {
  echo ">>> DIAG: Subscription (OLM, fully-qualified):"
  oc get subscription.operators.coreos.com quay-operator -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
  echo ">>> DIAG: events in ${INTEROP__OPP__QUAY__NAMESPACE} (last 50):"
  oc get events -n "${INTEROP__OPP__QUAY__NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: events in openshift-marketplace (last 50):"
  oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>&1 | tail -50 || true
  echo ">>> DIAG: CSVs in ${INTEROP__OPP__QUAY__NAMESPACE}:"
  oc get csv -n "${INTEROP__OPP__QUAY__NAMESPACE}" 2>&1 | head -50 || true
  echo ">>> DIAG: QuayRegistry registry status:"
  oc get quayregistries.quay.redhat.com registry -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o yaml 2>&1 | head -c 262144 || true
  echo
}

# Backstop for the create-admin-user Job log. The Job prints method and path
# only, never a request or response body, but its log is copied into the
# artifact directory with the trace, so a credential-shaped field or
# authorization header that does reach it is redacted before it is printed.
_scrub_job_log() {
  sed -E \
    -e 's/("(client_secret|password|access_token|token|basic|encrypted_password)"[[:space:]]*:[[:space:]]*")[^"]*/\1REDACTED/g' \
    -e 's/(Authorization: (Bearer|Basic) )[^[:space:]]+/\1REDACTED/g' \
    -e 's/(password|token|secret|key|credential)=[^ ]*/\1=REDACTED/gi'
}

if [[ "${INTEROP__OPP__QUAY__REPORT_ONLY}" == "1" ]]; then
  # Detection, not gating: report object states and exit 0. Runs before the
  # packagemanifest precondition on purpose (detection must work when the
  # catalog is absent or erroring) and before the self-disable check so the
  # full property set is recorded even when an OperatorPolicy owns the install.
  # A failed read is kept as its own state (undecided), never folded into the
  # absent/empty answer: detection output must not report an API or RBAC error
  # as an object state.
  _sub=$(oc get subscription.operators.coreos.com quay-operator -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{.spec.channel}') || _sub="undecided"
  _csvp=$(oc get csv -n "${INTEROP__OPP__QUAY__NAMESPACE}" -l "operators.coreos.com/quay-operator.${INTEROP__OPP__QUAY__NAMESPACE}=" -o jsonpath='{.items[0].status.phase}') || _csvp="undecided"
  _qr=$(oc get quayregistries.quay.redhat.com registry -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}') || _qr="undecided"
  _pm=$(oc get packagemanifest quay-operator -n openshift-marketplace -o name) || _pm="undecided"
  if [[ "${_pm}" == "undecided" ]]; then
    _pm_state="undecided"
  elif [[ -n "${_pm}" ]]; then
    _pm_state="present"
  else
    _pm_state="absent"
  fi
  _prop "report_only" "true"
  _prop "channel_observed" "${_sub:-absent}"
  _prop "csv_phase" "${_csvp:-absent}"
  _prop "quay_registry_conditions" "${_qr:-absent}"
  _prop "packagemanifest" "${_pm_state}"
  echo ">>> REPORT_ONLY: channel=${_sub:-absent} csv=${_csvp:-absent} packagemanifest=${_pm_state}"
  exit 0
fi

# _quay_admin_secrets_state: present|absent|query-failed for the four admin
# Secrets the policy Job creates (quayadmin with admin token/password/basic,
# quaydevel for the devel user, quay-pull-secret as dockerconfigjson and
# quay-integration as an automation token), all of which must exist before the
# Job counts as done. Defined here because the self-disable predicate records
# this state as well. As with the Job, only NotFound reports absence: a non-zero result that
# is an API or RBAC error must not read as "the Secrets are missing", because the
# step would then delete a healthy finished Job and install a replacement that
# its own quaydevel guard dooms.
_quay_admin_secrets_state() {
  local _s _out="" _fails
  for _s in quayadmin quaydevel quay-pull-secret quay-integration; do
    _fails=0
    while :; do
      if _out=$(oc get secret "${_s}" -n "${INTEROP__OPP__QUAY__NAMESPACE}" --request-timeout="$(_left_budget 20)" 2>&1); then
        break
      fi
      if grep -qF '(NotFound)' <<<"${_out}"; then
        echo absent
        return 0
      fi
      (( _fails += 1 )) || true
      if (( _fails >= 3 )); then
        echo ">>> secret ${_s}: 3 consecutive queries failed (last: $(printf '%s' "${_out}" | head -1))" >&2
        echo query-failed
        return 0
      fi
      sleep 1
    done
  done
  echo present
  return 0
}

# _quay_admin_secrets_query_fail: three consecutive Secret queries failed, so the
# step cannot tell a partial install from a read error and must not act.
_quay_admin_secrets_query_fail() {
  _classify "quay-admin-secrets-query-failed" "3 consecutive admin Secret queries failed (API or RBAC error, not absence)"
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
}

# _quay_admin_job_snapshot: "<state> <uid>" for the create-admin-user Job, both
# from ONE response, so the state and the identity that guards the delete can
# never describe two different objects. States: absent|complete|failed|live|
# query-failed, with uid "-" when the Job does not exist. One jsonpath read per
# try as in _poll_jsonpath: NotFound is the only non-zero result that reports
# absence, so an API or RBAC error is never read as "no Job running".
_quay_admin_job_snapshot() {
  local _out="" _payload="" _fails=0 _uid _conds _state _word
  while :; do
    _payload=""
    if _out=$(oc get job create-admin-user -n "${INTEROP__OPP__QUAY__NAMESPACE}" --request-timeout="$(_left_budget 20)" \
      -o jsonpath='__quay_job__{.metadata.uid}{" "}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>&1); then
      # A successful read can still write to stderr (a deprecation warning, a
      # rate-limiter notice); the sentinel keeps that text out of the UID.
      _payload=${_out##*__quay_job__}
      if [[ "${_payload}" == "${_out}" ]]; then
        _payload=""
      fi
    fi
    if [[ -n "${_payload}" ]]; then
      _payload=${_payload%%$'\n'*}
      _uid=${_payload%% *}
      _conds=${_payload#* }
      # Whole tokens only: a warning that follows the payload must not supply a
      # state word.
      _state="live"
      for _word in ${_conds}; do
        case "${_word}" in
          Complete) _state="complete" ;;
          Failed) _state="failed" ;;
        esac
      done
      echo "${_state} ${_uid}"
      return 0
    fi
    if grep -qF '(NotFound)' <<<"${_out}"; then
      echo "absent -"
      return 0
    fi
    (( _fails += 1 )) || true
    if (( _fails >= 3 )); then
      echo ">>> create-admin-user Job: 3 consecutive queries failed (last: $(printf '%s' "${_out}" | head -1))" >&2
      echo "query-failed -"
      return 0
    fi
    sleep 1
  done
}

# _quay_admin_job_state: the state alone, for the decision points that do not
# need the identity.
_quay_admin_job_state() {
  local _line
  _line=$(_quay_admin_job_snapshot)
  echo "${_line%% *}"
}

# _quay_admin_job_query_fail: three consecutive Job queries failed, which is an
# API or RBAC error and not absence, so the step must not guess a state.
_quay_admin_job_query_fail() {
  _classify "quay-admin-job-query-failed" "3 consecutive create-admin-user Job queries failed (API or RBAC error, not absence)"
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
}

# _quay_admin_log: the create-admin-user Job log with credential-shaped values
# masked. The ported Job discards the bodies it does not need, but a Job an
# OperatorPolicy created can log the response bodies it receives, and those
# carry the quaydevel client_secret or an access_token. The log is copied into
# the Prow log on failure, which must not gain credentials this step never
# printed.
_quay_admin_log() {
  oc logs job/create-admin-user -n "${INTEROP__OPP__QUAY__NAMESPACE}" --tail=200 2>&1 \
    | sed -E 's/("(client_secret|password|access_token|token|basic|encrypted_password)"[[:space:]]*:[[:space:]]*")[^"]*/\1REDACTED/g' \
    | head -c 65536
}

# _quay_admin_job_fail: a Failed Job is terminal and authoritative even when the
# four Secrets exist. The Job creates quay-integration before the organization,
# application, repository and permission calls, so a Job that stopped at one of
# those leaves usable Secrets and no devel org or devel/example repo. Adopting
# on secret presence alone would report success for a registry the documented
# smoke step cannot use.
#     The reason is recorded too: reason=DeadlineExceeded means
#     activeDeadlineSeconds ended the Job, which is how a hang shows up at the
#     default budgets.
_quay_admin_job_fail() {
  local _failed _reason
  _failed=$(oc get job create-admin-user -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{.status.failed}') || _failed=""
  _reason=$(oc get job create-admin-user -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{"/"}{.reason}{" "}{end}') || _reason=""
  _reason=$(printf '%s' "${_reason}" | sed -n 's/.*Failed\/\([^ ]*\).*/\1/p')
  echo ">>> DIAG: create-admin-user Job logs (tail 200):"
  _quay_admin_log || true
  _classify "quay-admin-job-failed" "create-admin-user Job reported condition Failed=True (reason=${_reason:-unknown}, failed pods=${_failed:-none}); existing Secrets are kept but the organization, application, repository and permission setup may not have finished"
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
}

# _quay_auth_curl: the registry reads authenticate with the quayadmin token. The
# token travels in a curl config on a file descriptor so it never appears in the
# process arguments. A Basic credential cannot replace it: Quay applies its
# OAuth decorator to every v1 resource, so a Basic header is ignored and the read
# runs anonymous. Callers bracket the call with set +x / set -x: the token is an
# argument, so the trace records the expanded value, and the cleanup scrub below
# matches 'token=' and 'Bearer <value>' shapes but never a bare token.
_quay_auth_curl() {
  local _cred=$1
  shift
  curl -sk -K <(printf 'header = "Authorization: Bearer %s"\n' "${_cred}") "$@"
}

# _quay_token_rejected <what> <kind> <code>: a 401 or 403 on a registry read.
# On a registry whose Secrets this step did not write the token can be older than
# its 150-minute lifetime, so there it is a warning and the caller records that
# part as unverified; a token minted by a Job this step started that is rejected
# is a real defect and fails the step. Sets _rejected and appends to
# _rejected_kind in the caller, which declares both.
_quay_token_rejected() {
  local _what=$1 _kind=$2 _code=$3
  if (( ${_install_adopted:-0} )); then
    _rejected=1
    _rejected_kind="${_rejected_kind} ${_kind}"
    echo ">>> NOTE: ${_what} answered '${_code}' on https://${_host}; the stored quayadmin token was rejected (expired, revoked or lacking the access) and that part stays unverified (this step did not write those Secrets)"
    return 0
  fi
  _classify "quay-admin-token-rejected" "${_what} answered '${_code}'; the stored quayadmin token was rejected (expired, revoked or lacking the access)"
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
}

# _quay_devel_repo_role <direct|transitive>: the role the API reports for
# quaydevel on devel/example. The user is named in the URL, so the answer is
# about quaydevel and not about the token's owner (the token is quayadmin's).
# The direct read returns the direct repository row, which is the grant the Job
# writes; the transitive read resolves the same for a grant made through a team.
# Echoes admin, other, rejected:<code> or unreachable:<code>.
_quay_devel_repo_role() {
  local _kind="${1:-direct}" _suffix="" _body _code
  [[ "${_kind}" == "transitive" ]] && _suffix="/transitive"
  set +x 2>/dev/null
  _body=$(_quay_auth_curl "${_token}" --connect-timeout "$(_left_budget 10)" --max-time "$(_left_budget 20)" -w '\n%{http_code}' \
    "https://${_host}/api/v1/repository/devel/example/permissions/user/quaydevel${_suffix}") || _body=""
  set -x
  _code=${_body##*$'\n'}
  _body=${_body%$'\n'*}
  case "${_code}" in
    200)
      if grep -qE '"role"[[:space:]]*:[[:space:]]*"admin"' <<<"${_body}"; then
        echo admin
      else
        echo other
      fi
      ;;
    401 | 403) echo "rejected:${_code}" ;;
    404) echo "other" ;;
    # Any non-200/404 response is treated as unreachable; a 500 does not mean "no admin row".
    *) echo "unreachable:${_code:-no-response}" ;;
  esac
}

# _quay_org_repo_check: the OPP lanes push to devel/example, so a registry
# without the devel organization or that repository is not usable. The adopt
# branches trust four Secrets and a Job that reported Complete, and the upstream
# Job text ignores quay_cmd's status on the organization and repository calls,
# so a policy-owned Job can be Complete with the Secrets and no organization:
# verify both objects directly instead of trusting the Job's status.
# The reads use the access token the initialize call returned. That token expires
# after 150 minutes (the Job text records the same limit), so on an adopted
# registry the stored token can be older than its lifetime: a rejected token
# there is reported as a warning and the objects stay unverified rather than
# failing a registry whose Secrets this step did not write. A Job started by this
# step mints its token during the step, so a rejection on that path is a real
# defect and fails the step.
_quay_org_repo_check() {
  local _token _host _path _code _grant _rejected=0 _rejected_kind=
  if (( _work_deadline - _diag_reserve - $(date +%s) < 160 )); then
    # The check itself costs up to 140s (two 20s oc reads, two 30s object curls
    # and two 20s permission curls).
    # Starting it with less would TERM the step and write StepTerminated over the
    # real classification.
    _classify "quay-admin-verify-timeout" "less than 160s of work budget left when the Quay registry check started; the check did not run, so the Objects may still be present"
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
  fi
  # The token read is bracketed for the same reason as the _quay_auth_curl
  # callers: xtrace prints the expanded value of an assignment whose right-hand
  # side is a command substitution.
  set +x 2>/dev/null
  _token=$(oc get secret quayadmin -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d) || _token=""
  set -x
  _host=$(oc get route -n "${INTEROP__OPP__QUAY__NAMESPACE}" registry-quay -o jsonpath='{.spec.host}') || _host=""
  if [[ -z "${_token}" ]]; then
    _classify "quay-admin-secrets-query-failed" "the quayadmin token is empty or unreadable, so the registry reads cannot be authenticated"
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
  fi
  if [[ -z "${_host}" ]]; then
    _classify "quay-admin-registry-unreachable" "the registry-quay route has no host, so the registry reads cannot be addressed"
    echo "ERROR: ${_class_detail}"
    _dump_diagnostics
    exit 1
  fi
  for _path in /api/v1/organization/devel /api/v1/repository/devel/example; do
    set +x 2>/dev/null
    _code=$(_quay_auth_curl "${_token}" -o /dev/null -w '%{http_code}' --connect-timeout "$(_left_budget 10)" --max-time "$(_left_budget 30)" \
      "https://${_host}${_path}") || _code=""
    set -x
    case "${_code}" in
      200) ;;
      401 | 403)
        # A rejected token (or one that lacks the access) is not a missing
        # object: say so, or the operator looks for an organization that is
        # there.
        _quay_token_rejected "${_path}" object "${_code}"
        continue
        ;;
      404)
        _classify "quay-admin-org-missing" "${_path} answered '404' on https://${_host}; the devel organization or the devel/example repository is missing"
        echo "ERROR: ${_class_detail}"
        _dump_diagnostics
        exit 1
        ;;
      *)
        # A 5xx or no response at all says nothing about the object: classing it
        # as missing sends the operator after an organization that may be there.
        _classify "quay-admin-registry-unreachable" "${_path} answered '${_code:-no-response}' on https://${_host}; the registry did not answer, so the devel organization and repository are unverified"
        echo "ERROR: ${_class_detail}"
        _dump_diagnostics
        exit 1
        ;;
    esac
  done
  # Existing objects are not enough: the lanes push to devel/example as
  # quaydevel. The Job writes a direct admin repository row for quaydevel, so the
  # step reads that row and,
  # when it is not admin, the transitive read, which resolves a grant made through
  # a team. Both reads are repository scoped, so an organization admin team is
  # invisible to them (the organization body reports only the caller's own admin
  # status, and the caller is quayadmin here), and neither read can rule that out:
  # when neither answers admin the grant is recorded unverified instead of
  # failing an install whose Job write is already guarded. The bodies are read for
  # the role only and are never echoed.
  _grant=$(_quay_devel_repo_role)
  case "${_grant}" in
    admin) ;;
    rejected:*)
      _quay_token_rejected "the quaydevel repository permission read" grant "${_grant#rejected:}"
      _grant=unverified
      ;;
    *)
      _grant=$(_quay_devel_repo_role transitive)
      case "${_grant}" in
        admin) _grant=team ;;
        rejected:*)
          _quay_token_rejected "the quaydevel transitive permission read" grant "${_grant#rejected:}"
          _grant=unverified
          ;;
        unreachable:*)
          _classify "quay-admin-registry-unreachable" "the quaydevel transitive permission read answered '${_grant#unreachable:}' on https://${_host}; the registry did not answer, so the devel/example grant is unverified"
          echo "ERROR: ${_class_detail}"
          _dump_diagnostics
          exit 1
          ;;
        *)
          echo ">>> NOTE: neither the direct nor the transitive permission read reports an admin grant for quaydevel on devel/example; a grant held through an admin-role organization team is not visible to either read, so the grant stays unverified"
          _grant=unverified
          ;;
      esac
      ;;
  esac
  case "${_grant}" in
    admin) _prop "quay_repo_permission" "admin" ;;
    team) _prop "quay_repo_permission" "admin-via-team" ;;
    *) : ;;
  esac
  case " ${_rejected_kind} " in
    *" object "*) _prop "quay_org_repo" "unverified" ;;
    *) _prop "quay_org_repo" "present" ;;
  esac
  case " ${_rejected_kind} " in
    *" grant "*) _prop "quay_repo_permission" "unverified" ;;
  esac
  if (( _rejected )); then
    _prop "quay_admin_token" "rejected"
    return 0
  fi
  if [[ "${_grant}" == "unverified" ]]; then
    _prop "quay_repo_permission" "unverified"
  fi
  return 0
}

# --- Self-disable predicate ---
# operatorpolicy-quay-operator Compliant AND subscription channel matches AND
# CSV Succeeded AND QuayRegistry registry in local-quay Available=true.
# Queried cluster-wide by name (ACM installs the OperatorPolicy in the managed
# cluster namespace, local-cluster) and the observed namespace is recorded; an
# absent/NonCompliant policy is simply "no second writer yet".
_prop "channel_requested" "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}"
if oc get crd operatorpolicies.policy.open-cluster-management.io >/dev/null 2>&1; then
  _op_status=$(oc get operatorpolicies.policy.open-cluster-management.io -A -o json) || _op_status="undecided"
  if [[ "${_op_status}" == "undecided" ]]; then
    # A failed read is not "no policy". The self-disable verdict is withheld
    # (the install path runs and the policy is never patched) and the state is
    # reported instead of read as an absence.
    echo ">>> NOTE: operatorpolicy list read failed (API/RBAC error); self-disable withheld, install path runs"
  elif [[ -n "${_op_status}" ]]; then
    typeset _sd_policy="operatorpolicy-quay-operator"
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
' "${_sd_policy}" "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}") || _sd_out="absent - -"
    _sd_ok="absent" _sd_ns="-" _sd_ch="-"
    read -r _sd_ok _sd_ns _sd_ch <<<"${_sd_out}"
    _prop "operatorpolicy_namespace" "${_sd_ns:-unknown}"
    _prop "operatorpolicy_channel" "${_sd_ch:-unknown}"
    # The policy's spec channel is the REQUESTED channel, not the live one, so
    # a cluster whose Subscription already runs a different channel must not
    # self-disable (that would leave the requested channel uninstalled). The
    # Subscription is named for the package, not derivable from the policy name
    # in general, so the name is literal here and matches the create-if-absent
    # and REPORT_ONLY reads. It is read in the operator namespace the
    # OperatorPolicy places it in, falling back to the policy namespace.
    # Absent/unreadable is recorded as unknown and does not withhold the
    # self-disable on its own.
    typeset _sd_sub="quay-operator"
    typeset _live_ch=""
    _live_ch=$(oc get subscription.operators.coreos.com "${_sd_sub}" -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{.spec.channel}') || _live_ch=""
    if [[ -z "${_live_ch}" && "${_sd_ns}" != "-" && "${_sd_ns}" != "${INTEROP__OPP__QUAY__NAMESPACE}" ]]; then
      _live_ch=$(oc get subscription.operators.coreos.com "${_sd_sub}" -n "${_sd_ns}" -o jsonpath='{.spec.channel}') || _live_ch=""
    fi
    _prop "live_subscription_channel" "${_live_ch:-unknown}"
    if [[ "${_sd_ok}" == "true" && ( -z "${_live_ch}" || "${_live_ch}" == "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}" ) ]]; then
      _existing_csv=$(oc get csv -n "${INTEROP__OPP__QUAY__NAMESPACE}" -l "operators.coreos.com/quay-operator.${INTEROP__OPP__QUAY__NAMESPACE}=" -o jsonpath='{.items[0].status.phase}') || _existing_csv="undecided"
      if [[ "${_existing_csv}" == "Succeeded" ]]; then
        _qr_avail=$(oc get quayregistries.quay.redhat.com registry -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}') || _qr_avail="undecided"
        if grep -qx 'Available=True' <<<"${_qr_avail}"; then
          # Registry availability says nothing about admin initialization: a
          # policy-owned Job may still be running. Record the credential state
          # instead of gating on it, because driving an already-initialized
          # database back through the single-shot Job turns a healthy install
          # into quay-admin-partial-state.
          _sd_secret_state=$(_quay_admin_secrets_state)
          _prop "quay_admin_secrets_at_self_disable" "${_sd_secret_state}"
          if [[ "${_sd_secret_state}" != "present" ]]; then
            echo ">>> NOTE: QuayRegistry is Available but quayadmin/quaydevel/quay-pull-secret/quay-integration are not all present yet; the quay smoke step needs them"
          fi
          # A policy-owned Job that failed stopped somewhere in the admin
          # sequence (it writes quay-integration before the org and repo setup),
          # so "workaround removal ready" would be a false green. An absent or
          # unreadable state stays a recorded observation here: this branch must
          # not install, and the smoke step reports the missing objects.
          _sd_job_state=$(_quay_admin_job_state)
          _prop "quay_admin_job_at_self_disable" "${_sd_job_state}"
          if [[ "${_sd_job_state}" == "failed" ]]; then
            _quay_admin_job_fail
          fi
          echo ">>> workaround_removal_ready=true (OperatorPolicy Compliant, channel ${_sd_ch}, CSV Succeeded, QuayRegistry Available) - not installing"
          _prop "workaround_removal_ready" "true"
          _prop "quay_subscription" "adopted"
          _prop "csv_phase" "Succeeded"
          _prop "quay_registry_available" "True"
          exit 0
        fi
        if [[ "${_qr_avail}" == "undecided" ]]; then
          # A failed read is not "not Available": the self-disable is withheld
          # (the install path below is create-if-absent) and the state is
          # reported instead of read as a definite negative.
          echo ">>> NOTE: QuayRegistry conditions read failed (API/RBAC error); self-disable withheld, install path runs"
        else
          echo ">>> NOTE: OperatorPolicy Compliant and CSV Succeeded but QuayRegistry is not Available yet - installing"
        fi
      elif [[ "${_existing_csv}" == "undecided" ]]; then
        echo ">>> NOTE: CSV phase read failed (API/RBAC error); self-disable withheld, install path runs"
      fi
    elif [[ "${_sd_ok}" == "true" ]]; then
      # Policy Compliant on the requested channel, but the live Subscription
      # runs a different one: the CSV below would be another channel's, so it
      # must not stand in for this channel's install. The install path is
      # create-if-absent, so an existing Subscription is adopted as-is (never
      # patched: a live OperatorPolicy owns it) and the mismatch is recorded as
      # channel_self_disable_withheld; the requested channel is not installed over it.
      echo ">>> NOTE: live Subscription channel '${_live_ch}' != requested '${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}': self-disable withheld, install path runs (existing Subscription adopted, not patched)"
      _prop "channel_self_disable_withheld" "${_live_ch}!=${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}"
    elif [[ "${_sd_ch}" != "-" && "${_sd_ch}" != "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}" ]]; then
      echo ">>> NOTE: OperatorPolicy channel '${_sd_ch}' != requested '${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}': self-disable withheld, installing"
      _prop "channel_self_disable_withheld" "${_sd_ch}!=${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}"
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
  if grep -qi "not found" <<<"${_pm_raw}"; then
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
' "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}") || _channel_ok="error"
case "${_channel_ok}" in
  absent*)
    _classify "quay-catalog-missing" "channel '${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}' not listed for quay-operator (${_channel_ok#absent })"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
  error)
    _classify "quay-catalog-query-failed" "packagemanifest channel listing unparseable (query succeeded but returned non-JSON)"
    echo "ERROR: ${_class_detail}"
    exit 1
    ;;
esac
echo ">>> precondition: quay-operator present; channel ${INTEROP__OPP__QUAY__OPERATOR_CHANNEL} head: ${_channel_ok#ok }"

# --- Create-if-absent: namespace (policy-install-quay.yaml carries the
#     cluster-monitoring label; ensured idempotently) ---
if oc get namespace "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
  _prop "quay_namespace" "adopted"
else
  if oc create namespace "${INTEROP__OPP__QUAY__NAMESPACE}" 2>&1; then
    _prop "quay_namespace" "created"
  elif oc get namespace "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
    _prop "quay_namespace" "race-tolerated"
  else
    _classify "quay-namespace-error" "failed to create namespace ${INTEROP__OPP__QUAY__NAMESPACE}"
    echo "ERROR: ${_class_detail}"
    exit 1
  fi
fi
oc label namespace "${INTEROP__OPP__QUAY__NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite >/dev/null 2>&1 || true

# --- Create-if-absent: OperatorGroup (name local-quay, targetNamespaces
#     [local-quay]; any existing group is adopted; a second group in one
#     namespace puts CSVs into TooManyOperatorGroups). oc create, not apply: if
#     a second writer (a live OperatorPolicy) wins the race, create fails
#     AlreadyExists and we adopt; never overwrite spec.targetNamespaces. ---
if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o name)" ]]; then
  _prop "quay_operatorgroup" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${INTEROP__OPP__QUAY__NAMESPACE}
  namespace: ${INTEROP__OPP__QUAY__NAMESPACE}
spec:
  targetNamespaces:
    - ${INTEROP__OPP__QUAY__NAMESPACE}
EOF
  then
    if [[ -n "$(oc get operatorgroups.operators.coreos.com -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o name)" ]]; then
      _prop "quay_operatorgroup" "race-tolerated"
      echo ">>> NOTE: OperatorGroup created concurrently by another writer - adopting"
    else
      _classify "quay-operatorgroup-create-error" "failed to create OperatorGroup ${INTEROP__OPP__QUAY__NAMESPACE} in ${INTEROP__OPP__QUAY__NAMESPACE}"
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
if oc get subscription.operators.coreos.com quay-operator -n "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
  _existing_ch=$(oc get subscription.operators.coreos.com quay-operator -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{.spec.channel}') || _existing_ch="unknown"
  _prop "quay_subscription" "adopted"
  _prop "channel_observed" "${_existing_ch}"
  if [[ "${_existing_ch}" != "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}" ]]; then
    echo ">>> NOTE: existing Subscription channel '${_existing_ch}' != requested '${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}' - adopting, not overwriting (a live OperatorPolicy is the owner)"
    _prop "channel_mismatch" "${_existing_ch}!=${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}"
  fi
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: ${INTEROP__OPP__QUAY__NAMESPACE}
  labels:
    operators.coreos.com/quay-operator.${INTEROP__OPP__QUAY__NAMESPACE}: ""
spec:
  channel: "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: quay-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  then
    if oc get subscription.operators.coreos.com quay-operator -n "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
      _prop "quay_subscription" "race-tolerated"
      _prop "channel_observed" "$(oc get subscription.operators.coreos.com quay-operator -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{.spec.channel}' || echo unknown)"
      echo ">>> NOTE: Subscription created concurrently by another writer - adopting"
    else
      _classify "quay-subscription-create-error" "failed to create Subscription quay-operator"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "quay_subscription" "created"
    _prop "channel_observed" "${INTEROP__OPP__QUAY__OPERATOR_CHANNEL}"
  fi
fi

# --- Wait for the CSV name (read status.currentCSV; the patch version is
#     never hardcoded). Elapsed-time deadline, so a slow-but-successful
#     response is charged against the budget. ---
echo ">>> PHASE: waiting for the quay-operator CSV name (timeout: ${INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT}s)"
_csv_want=$(( $(date +%s) + INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_csv_want}")
if (( _poll_deadline < _csv_want )); then
  echo ">>> NOTE: CSV-name wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath subscription.operators.coreos.com quay-operator "${INTEROP__OPP__QUAY__NAMESPACE}" '{.status.currentCSV}' '@any' '' "quay-operator currentCSV"; then
  csvName="${_poll_last}"
  _prop "csv_name" "${csvName}"
else
  _prc=$?
  _cond=$(oc get subscription.operators.coreos.com quay-operator -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {end}') || _cond="undecided"
  if (( _prc == 2 )); then
    _classify "quay-subscription-query-failed" "3 consecutive subscription queries failed (rc captured; API/RBAC error, not absence)"
  else
    case "${_cond}" in
      *CatalogSourcesUnhealthy=True*) _classify "quay-catalog-missing" "Subscription condition CatalogSourcesUnhealthy=True" ;;
      *ConstraintsNotSatisfiable*)    _classify "quay-subscription-unsatisfiable" "Subscription condition ConstraintsNotSatisfiable" ;;
      *InstallPlanMissing*)           _classify "quay-installplan-missing" "Subscription condition InstallPlanMissing" ;;
      *InstallPlanFailed*)            _classify "quay-installplan-failed" "Subscription condition InstallPlanFailed" ;;
      *)                              _classify "quay-csv-timeout" "no currentCSV after ${INTEROP__OPP__QUAY__CSV_WAIT_TIMEOUT}s (conditions: ${_cond:-none})" ;;
    esac
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> quay-operator CSV: ${csvName}"

# --- Wait for CSV Succeeded (a not-yet-created CSV object is waited out, not
#     classified as an API failure). ---
echo ">>> PHASE: waiting for CSV ${csvName} Succeeded (timeout: ${INTEROP__OPP__QUAY__INSTALL_TIMEOUT}s)"
_install_want=$(( $(date +%s) + INTEROP__OPP__QUAY__INSTALL_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_install_want}")
if (( _poll_deadline < _install_want )); then
  echo ">>> NOTE: CSV-Succeeded wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${INTEROP__OPP__QUAY__INSTALL_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath clusterserviceversions.operators.coreos.com "${csvName}" "${INTEROP__OPP__QUAY__NAMESPACE}" '{.status.phase}' Succeeded Failed "CSV ${csvName} phase"; then
  _prop "csv_phase" "Succeeded"
else
  _prc=$?
  if (( _prc == 3 )); then
    _classify "quay-csv-failed" "CSV ${csvName} reached phase Failed"
  elif (( _prc == 2 )); then
    _classify "quay-subscription-query-failed" "3 consecutive CSV queries for ${csvName} failed (API/RBAC error, not absence)"
  else
    _classify "quay-csv-timeout" "CSV ${csvName} not Succeeded after ${INTEROP__OPP__QUAY__INSTALL_TIMEOUT}s (phase: ${_poll_last:-unknown})"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> quay-operator CSV Succeeded"

# --- Secret init-config-bundle-secret (data.config.yaml verbatim from
#     policy-install-quay.yaml: user initialize, superusers [quayadmin]) ---
if oc get secret init-config-bundle-secret -n "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
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
  if oc create secret generic init-config-bundle-secret -n "${INTEROP__OPP__QUAY__NAMESPACE}" --from-file=config.yaml="${_bundle_tmp}" 2>&1; then
    _prop "init_bundle_secret" "created"
  elif oc get secret init-config-bundle-secret -n "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
    _prop "init_bundle_secret" "race-tolerated"
  else
    _classify "quay-secret-error" "failed to create Secret init-config-bundle-secret in ${INTEROP__OPP__QUAY__NAMESPACE}"
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
if oc get quayregistries.quay.redhat.com registry -n "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
  _prop "quay_registry" "adopted"
else
  if ! cat <<EOF | oc create -f - 2>&1
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: registry
  namespace: ${INTEROP__OPP__QUAY__NAMESPACE}
spec:
  configBundleSecret: init-config-bundle-secret
  components:
    - kind: objectstorage
      managed: true
    - managed: true
      kind: tls
EOF
  then
    if oc get quayregistries.quay.redhat.com registry -n "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
      _prop "quay_registry" "race-tolerated"
    else
      _classify "quay-registry-error" "failed to create QuayRegistry registry in ${INTEROP__OPP__QUAY__NAMESPACE}"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  else
    _prop "quay_registry" "created"
  fi
fi

# --- Wait for QuayRegistry Available=True ---
echo ">>> PHASE: waiting for QuayRegistry registry Available (timeout: ${INTEROP__OPP__QUAY__REGISTRY_TIMEOUT}s)"
_reg_want=$(( $(date +%s) + INTEROP__OPP__QUAY__REGISTRY_TIMEOUT ))
_poll_deadline=$(_clamp_deadline "${_reg_want}")
if (( _poll_deadline < _reg_want )); then
  echo ">>> NOTE: QuayRegistry wait clamped to $(( _poll_deadline - $(date +%s) ))s (requested ${INTEROP__OPP__QUAY__REGISTRY_TIMEOUT}s) to stay inside the shared ${_work_budget}s work budget"
fi
if _poll_jsonpath quayregistries.quay.redhat.com registry "${INTEROP__OPP__QUAY__NAMESPACE}" \
    '{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' '@contains:Available=True' '' "QuayRegistry registry conditions"; then
  _prop "quay_registry_available" "True"
else
  _prc=$?
  if (( _prc == 2 )); then
    _classify "quay-registry-query-failed" "3 consecutive QuayRegistry queries failed (API/RBAC error, not absence)"
  else
    _classify "quay-registry-timeout" "QuayRegistry registry never reported Available=True within ${INTEROP__OPP__QUAY__REGISTRY_TIMEOUT}s (last: $(printf '%s' "${_poll_last:-absent}" | tr '\n' ' '))"
  fi
  echo "ERROR: ${_class_detail}"
  _dump_diagnostics
  exit 1
fi
echo ">>> QuayRegistry registry Available"

# --- create-admin-user machinery: SA/Role/RoleBinding (policy-install-quay)
#     and the Job (policy-config-quay) that initializes the Quay DB and creates
#     the quayadmin / quaydevel / quay-pull-secret / quay-integration secrets,
#     org devel and repo devel/example. Ported with three reviewed deviations
#     from the upstream text: QUAY_USER_EMAIL is defined (upstream leaves it
#     undefined), user/initialize uses curl -fsSLk with an explicit failure exit
#     (upstream uses curl -k -s without -f), and quayadmin's basic credential
#     encodes the admin account (upstream derives it from QUAY_PASSWORD before
#     that variable is assigned, so it encodes "quaydevel:" with an empty
#     password; the upstream defect is INTEROP-9724). Two further departures from
#     the upstream text are already in the ported step and are not part of this
#     hardening: quay_cmd returns curl's status instead of its own success echo,
#     and the route read is checked where it happens. The hardening on top of the
#     port adds quay_require (it fails the Job on the calls that must succeed),
#     the access_token and generated-password checks before the Secrets are
#     written, response bodies that carry client_secret discarded, the Secret
#     state separating absence from a query error, connect and total timeouts on
#     every Quay call, and activeDeadlineSeconds on the Job (the one manifest
#     divergence from the policy Job text) so it cannot outlive the admin phase.
#     The Job is first-run-only by construction (its own guard exits 1 when the
#     quaydevel secret already exists), so its state picks the branch: a live Job
#     is waited on and never deleted mid-flight, a Failed Job fails the step when
#     the four Secrets exist (it writes quay-integration before the org and repo
#     setup), a finished Job with all four Secrets is adopted, and a finished Job
#     without them is replaced, but only when its UID and terminal state are still
#     the ones observed: a name-only delete could remove a live replacement that
#     the policy created meanwhile.
# _quay_admin_secrets_state and _quay_admin_job_state are defined above the
# self-disable predicate: that predicate records the credential state too.
# The Secrets are read before the Job state: a Job that starts in that window
# finds the quaydevel Secret, exits on its own guard, and shows up as live or
# failed in the state read instead of being adopted mid-flight.
_admin_secrets=0
_secret_state=$(_quay_admin_secrets_state)
if [[ "${_secret_state}" == "query-failed" ]]; then
  _quay_admin_secrets_query_fail
fi
if [[ "${_secret_state}" == "present" ]]; then
  _admin_secrets=1
fi
_job_state=$(_quay_admin_job_state)
_job_wait=0
_decided_uid=""
_install_adopted=0
if [[ "${_job_state}" == "query-failed" ]]; then
  _quay_admin_job_query_fail
fi
if [[ "${_job_state}" == "failed" ]] && (( _admin_secrets )); then
  _quay_admin_job_fail
fi
if (( _admin_secrets )) && [[ "${_job_state}" != "live" ]]; then
  _install_adopted=1
  _prop "quay_admin_secrets" "adopted"
  _prop "quay_admin_job" "skipped-existing-secrets"
  echo ">>> create-admin-user: quayadmin/quaydevel/quay-pull-secret/quay-integration present and no Job in flight - adopting"
else
  echo ">>> PHASE: create-admin-user (Quay DB initialize, admin + devel user secrets)"
  cat <<EOF | oc create -f - 2>&1 || true
apiVersion: v1
kind: ServiceAccount
metadata:
  name: create-admin-user
  namespace: ${INTEROP__OPP__QUAY__NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: create-admin-user
  namespace: ${INTEROP__OPP__QUAY__NAMESPACE}
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
  namespace: ${INTEROP__OPP__QUAY__NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: create-admin-user
subjects:
  - kind: ServiceAccount
    name: create-admin-user
    namespace: ${INTEROP__OPP__QUAY__NAMESPACE}
EOF
  for _obj in serviceaccount/create-admin-user role/create-admin-user rolebinding/create-admin-user; do
    if ! oc get "${_obj}" -n "${INTEROP__OPP__QUAY__NAMESPACE}" >/dev/null 2>&1; then
      _classify "quay-admin-rbac-error" "missing ${_obj} in ${INTEROP__OPP__QUAY__NAMESPACE} after the create attempt"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
  done
  _prop "quay_admin_rbac" "present"

  # The RBAC creation above takes time, and a policy-owned Job may have started,
  # finished or failed meanwhile: re-read the Secrets and the Job state before
  # deciding, in that order (see above), so a stale observation cannot replace a
  # live Job or adopt a half-finished one.
  _admin_secrets=0
  _secret_state=$(_quay_admin_secrets_state)
  if [[ "${_secret_state}" == "query-failed" ]]; then
    _quay_admin_secrets_query_fail
  fi
  if [[ "${_secret_state}" == "present" ]]; then
    _admin_secrets=1
  fi
  read -r _job_state _decided_uid <<<"$(_quay_admin_job_snapshot)"
  # The Job the Secret observation describes: a later replacement invalidates it.
  _secrets_uid="${_decided_uid}"
  # A Job that finished between the Secret read and this one has written its last
  # Secrets, and the stale "absent" would send a healthy install down the
  # partial-state exit: re-read the Secrets once now that the Job is terminal.
  if [[ "${_job_state}" == "complete" || "${_job_state}" == "failed" ]] && ! (( _admin_secrets )); then
    _secret_state=$(_quay_admin_secrets_state)
    if [[ "${_secret_state}" == "query-failed" ]]; then
      _quay_admin_secrets_query_fail
    fi
    if [[ "${_secret_state}" == "present" ]]; then
      _admin_secrets=1
    fi
    # The re-read retries each Secret, so the Job can finish, appear or be
    # replaced while it runs: refresh the state and the UID that the decision and
    # the delete precondition use, or a stale "failed" would fail a healthy
    # install on a replacement Job's Secrets.
    read -r _job_state _decided_uid <<<"$(_quay_admin_job_snapshot)"
  fi
  if [[ "${_job_state}" == "query-failed" ]]; then
    _quay_admin_job_query_fail
  elif [[ "${_job_state}" == "failed" ]] && (( _admin_secrets )); then
    _quay_admin_job_fail
  elif [[ "${_job_state}" == "live" ]]; then
    # Deleting a live Job loses the credentials it has already generated, and the
    # single-shot replacement cannot re-initialize a non-empty database. Wait for
    # it instead, inside the same INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT budget, so the
    # step-level budget invariant still holds.
    _job_wait=1
    # No Job started by this step minted the token, so a rejection on a registry
    # read is reported as unverified rather than as a defect here.
    _install_adopted=1
    _prop "quay_admin_job_inherited" "live"
    echo ">>> create-admin-user Job is live; waiting for it instead of deleting or replacing it"
  elif (( _admin_secrets )); then
    # Another writer produced the Secrets, so the token is not this step's.
    _install_adopted=1
    _prop "quay_admin_secrets" "adopted-late"
    _prop "quay_admin_job" "skipped-existing-secrets"
    echo ">>> create-admin-user: all four secrets are present on re-read - not touching the Job"
  else
    # The policy Job is single-shot, not idempotent: it exits 1 when the
    # quaydevel secret already exists, and it exits 1 when Quay answers
    # "non-empty database" to /api/v1/user/initialize. So it can only populate an
    # EMPTY registry. A quayadmin secret without the rest means the database was
    # already initialized and the remaining objects are gone: re-running the Job
    # cannot repair that, and reporting it as an install failure would hide the
    # real cause. Fail fast with its own class instead.
    if _qa_out=$(oc get secret quayadmin -n "${INTEROP__OPP__QUAY__NAMESPACE}" --request-timeout="$(_left_budget 20)" 2>&1); then
      # A policy-owned Job that started after the snapshot above writes
      # quayadmin first, so presence alone can catch a healthy initialization in
      # flight. Re-read the state, and wait for a live Job instead of reporting
      # a partial install.
      read -r _partial_state _ <<<"$(_quay_admin_job_snapshot)"
      if [[ "${_partial_state}" == "query-failed" ]]; then
        _quay_admin_job_query_fail
      fi
      if [[ "${_partial_state}" == "live" ]]; then
        _job_state="live"
        _job_wait=1
        _install_adopted=1
        _prop "quay_admin_job_inherited" "live"
        echo ">>> create-admin-user Job is live; waiting for it instead of reporting a partial install"
      else
        # The Job went terminal between the Secret read above and this one, so
        # its last writes can sit in that read's blind spot: re-read before
        # declaring a partial install, and adopt the Job if it finished the work.
        if [[ "${_partial_state}" == "complete" || "${_partial_state}" == "failed" || "${_partial_state}" == "absent" ]]; then
          _secret_state=$(_quay_admin_secrets_state)
          if [[ "${_secret_state}" == "query-failed" ]]; then
            _quay_admin_secrets_query_fail
          fi
          if [[ "${_secret_state}" == "present" ]]; then
            # A Failed Job leaves the registry half-configured even with all four
            # Secrets, so it keeps its own class and its log, exactly as on the
            # branch above.
            if [[ "${_partial_state}" == "failed" ]]; then
              _quay_admin_job_fail
            fi
            _admin_secrets=1
            _install_adopted=1
            _prop "quay_admin_secrets" "adopted-late"
            _prop "quay_admin_job" "skipped-existing-secrets"
            echo ">>> create-admin-user: the Job finished and all four secrets are present on re-read - not touching the Job"
          fi
        fi
        if (( ! _admin_secrets )); then
          _classify "quay-admin-partial-state" "quayadmin exists but quaydevel/quay-pull-secret/quay-integration are not all present; the policy Job cannot re-initialize an already-initialized Quay database (see policy-config-quay.yaml create-admin-user)"
          echo "ERROR: ${_class_detail}"
          _dump_diagnostics
          exit 1
        fi
      fi
    elif ! grep -qF '(NotFound)' <<<"${_qa_out}"; then
      # A read timeout or an RBAC error is not absence: treating it as absence
      # deletes a terminal Job and lets the replacement die on its own guard.
      _classify "quay-admin-secrets-query-failed" "the quayadmin Secret could not be read after the Job decision ($(printf '%s' "${_qa_out}" | head -1)); presence is unknown, so the Job is left in place"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi

    # A live Job was handled above and a Failed Job with the four Secrets fails
    # the step, so only a finished Job reaches this point. A finished Job without
    # the Secrets is stale and is replaced: the Job's own guard and its
    # non-empty-database check keep a retry safe, and a retry is the only
    # recovery from a transient failure such as an unreachable route.
    if [[ "${_job_state}" == "complete" || "${_job_state}" == "failed" ]] && (( ! _admin_secrets )); then
      # Deleting by name can remove a Job this step never observed: a live
      # policy-owned Job that replaced the finished one while the RBAC objects
      # were created. Deleting it loses the credentials it generated, and its
      # replacement cannot re-initialize a non-empty database. Re-read the UID
      # and the state, and only delete the object observed as terminal.
      read -r _delete_state _delete_uid <<<"$(_quay_admin_job_snapshot)"
      if [[ "${_delete_state}" == "query-failed" ]]; then
        _quay_admin_job_query_fail
      fi
      if [[ "${_delete_state}" == "complete" || "${_delete_state}" == "failed" ]]; then
        if [[ "${_delete_uid}" != "${_decided_uid}" ]]; then
          # The replacement may have finished its work already: read its state
          # first and the four Secrets after it, so the Secrets answer describes
          # the state they are judged against and a replacement that wrote them
          # after the earlier read is still adopted.
          read -r _recheck_state _recheck_uid <<<"$(_quay_admin_job_snapshot)"
          if [[ "${_recheck_state}" == "query-failed" ]]; then
            _quay_admin_job_query_fail
          fi
          if [[ "${_recheck_state}" == "live" ]]; then
            # A third writer can hold the name and still be writing: wait for it
            # instead of reporting a replacement or verifying a half-written
            # registry. The wait loop below gates the create, and the delete is
            # gated on _job_wait so the live Job is never deleted.
            _job_state="${_recheck_state}"
            _job_wait=1
            _install_adopted=1
            _prop "quay_admin_job_inherited" "live"
            echo ">>> create-admin-user Job is live under the name after the Secrets re-read; waiting for it"
          else
            _secret_state=$(_quay_admin_secrets_state)
            if [[ "${_secret_state}" == "query-failed" ]]; then
              _quay_admin_secrets_query_fail
            fi
            # The Secret read retries, so the state read above can be older than
            # it: read the state once more and judge the Secrets, the Failed
            # verdict and the adoption against this read only.
            read -r _final_state _final_uid <<<"$(_quay_admin_job_snapshot)"
            if [[ "${_final_state}" == "query-failed" ]]; then
              _quay_admin_job_query_fail
            fi
            if [[ "${_final_state}" == "live" ]]; then
              _job_state="${_final_state}"
              _job_wait=1
              _install_adopted=1
              _prop "quay_admin_job_inherited" "live"
              echo ">>> create-admin-user Job is live after the Secrets re-read; waiting for it"
            elif [[ "${_secret_state}" != "present" ]]; then
              if [[ "${_final_state}" == "complete" ]]; then
                _secret_state=$(_quay_admin_secrets_state)
                if [[ "${_secret_state}" == "query-failed" ]]; then
                  _quay_admin_secrets_query_fail
                fi
                if [[ "${_secret_state}" == "present" ]]; then
                  _admin_secrets=1
                  _install_adopted=1
                  _prop "quay_admin_secrets" "adopted-late"
                  _prop "quay_admin_job" "skipped-existing-secrets"
                  echo ">>> create-admin-user: the Job was replaced and wrote all four secrets - not touching the Job"
                else
                  _classify "quay-admin-job-replaced" "create-admin-user Job was replaced while the RBAC objects were created (observed UID ${_decided_uid:-none}, now ${_final_uid:-none}); not deleting an object this step did not observe"
                  echo "ERROR: ${_class_detail}"
                  _dump_diagnostics
                  exit 1
                fi
              else
                if [[ "${_final_state}" == "failed" ]]; then
                  _quay_admin_job_fail
                fi
                _classify "quay-admin-job-replaced" "create-admin-user Job was replaced while the RBAC objects were created (observed UID ${_decided_uid:-none}, now ${_final_uid:-none}); not deleting an object this step did not observe"
                echo "ERROR: ${_class_detail}"
                _dump_diagnostics
                exit 1
              fi
            elif [[ "${_final_state}" == "failed" ]]; then
              _quay_admin_job_fail
            elif [[ "${_final_state}" == "absent" ]]; then
              echo ">>> NOTE: the replacement Job was removed after it wrote the four secrets; keeping them and leaving the Job alone"
              _admin_secrets=1
              _install_adopted=1
              _prop "quay_admin_secrets" "adopted-late"
              _prop "quay_admin_job" "skipped-existing-secrets"
            else
              _admin_secrets=1
              _install_adopted=1
              _prop "quay_admin_secrets" "adopted-late"
              _prop "quay_admin_job" "skipped-existing-secrets"
              echo ">>> create-admin-user: the Job was replaced and wrote all four secrets - not touching the Job"
            fi
          fi
        elif [[ "${_delete_uid}" != "${_secrets_uid}" ]]; then
          # The Secret observation describes an earlier Job, so its absence says
          # nothing about this one: a Job created in between can have written all
          # four Secrets and finished. Re-read before replacing it.
          _secret_state=$(_quay_admin_secrets_state)
          if [[ "${_secret_state}" == "query-failed" ]]; then
            _quay_admin_secrets_query_fail
          fi
          if [[ "${_secret_state}" == "present" ]]; then
            # The re-read retried four Secrets, so the state read above can be
            # older than it: read the state again before a Failed verdict.
            read -r _recheck_state _recheck_uid <<<"$(_quay_admin_job_snapshot)"
            if [[ "${_recheck_state}" == "query-failed" ]]; then
              _quay_admin_job_query_fail
            fi
            if [[ "${_recheck_state}" == "live" ]]; then
              # The writer that began after the Secret observation is still
              # running, so wait for it before verifying what it wrote.
              _job_state="${_recheck_state}"
              _job_wait=1
              _install_adopted=1
              _prop "quay_admin_job_inherited" "live"
              echo ">>> create-admin-user Job is live under the name after the Secrets re-read; waiting for it"
            else
              # A Failed Job leaves the registry half-configured even with all
              # four Secrets, so it keeps its own class and its log here too.
              if [[ "${_recheck_state}" == "failed" ]]; then
                _quay_admin_job_fail
              fi
              _admin_secrets=1
              _install_adopted=1
              _prop "quay_admin_secrets" "adopted-late"
              _prop "quay_admin_job" "skipped-existing-secrets"
              echo ">>> create-admin-user: the Job that replaced the observed one wrote all four secrets - not touching the Job"
            fi
          fi
        fi
      fi
      if (( ! _admin_secrets )) && (( ! _job_wait )) && [[ "${_delete_state}" == "complete" || "${_delete_state}" == "failed" ]]; then
        # The check above is a name-level read, so the delete carries the
        # observed UID as an API precondition: oc delete has no --uid flag, and a
        # replacement Job that appears between the read and the delete must make
        # the API reject the request (409 Conflict) instead of being deleted.
        # Background propagation is named because a raw batch/v1 DeleteOptions
        # without it orphans the Job's pods, while oc delete asks for background:
        # the delete then still frees the name and leaves no stale pods behind.
        _delete_opts=$(printf '{"apiVersion":"batch/v1","kind":"DeleteOptions","propagationPolicy":"Background","preconditions":{"uid":"%s"}}' "${_decided_uid}")
        _delete_rc=0
        _delete_out=$(oc delete --raw "/apis/batch/v1/namespaces/${INTEROP__OPP__QUAY__NAMESPACE}/jobs/create-admin-user" -f - 2>&1 <<<"${_delete_opts}") || _delete_rc=$?
        if (( _delete_rc == 0 )); then
          # --raw returns before the object is finalized: a Job holding the
          # job-tracking finalizer keeps its name until its pods report, and the
          # create below would then hit AlreadyExists and wait on a terminating
          # Job. Poll the name, bounded in wall-clock time and by the work
          # budget. Only absence means cleared: once the name is free the other
          # writer may legitimately create a Job of its own, which is adopted
          # like a concurrent create instead of failing the step. Read errors
          # are counted, not read as presence.
          _delete_wait=$(_left_budget 60)
          _delete_until=$(( $(date +%s) + _delete_wait ))
          _gone=0
          _recreated=0
          _strikes=0
          while :; do
            if ! _still_raw=$(oc get job create-admin-user -n "${INTEROP__OPP__QUAY__NAMESPACE}" --request-timeout="$(_left_budget 20)" -o jsonpath='__quay_job__{.metadata.uid}' 2>&1); then
              _still=${_still_raw}
              if grep -qF '(NotFound)' <<<"${_still_raw}"; then
                _gone=1
                break
              fi
              (( _strikes += 1 )) || true
              if (( _strikes >= 3 )); then
                _classify "quay-admin-job-query-failed" "the create-admin-user Job could not be read after the stale-Job delete ($(printf '%s' "${_still}" | head -1))"
                echo "ERROR: ${_class_detail}"
                _dump_diagnostics
                exit 1
              fi
            else
              # Strip anything a warning wrote to stderr before comparing, and
              # treat a success without the sentinel as unparseable rather than
              # as a different UID, or a warning would read as a recreate.
              _still=${_still_raw##*__quay_job__}
              if [[ "${_still}" == "${_still_raw}" ]]; then
                _still=""
              else
                # A warning can follow the payload, on the same line or on the
                # next: the UID is the first token of the first line.
                _still=${_still%%$'\n'*}
                _still=${_still%% *}
              fi
              if [[ -n "${_still}" && "${_still}" != "${_decided_uid}" ]]; then
                _recreated=1
                break
              fi
              if [[ -z "${_still}" ]]; then
                (( _strikes += 1 )) || true
                if (( _strikes >= 3 )); then
                  _classify "quay-admin-job-query-failed" "the create-admin-user Job could not be read after the stale-Job delete (unparseable read: $(printf '%s' "${_still_raw}" | head -1))"
                  echo "ERROR: ${_class_detail}"
                  _dump_diagnostics
                  exit 1
                fi
              else
                _strikes=0
              fi
            fi
            # At least one read runs, so a window shorter than the interval
            # cannot assert the outcome without looking.
            (( $(date +%s) < _delete_until )) || break
            sleep 2
          done
          if (( ! _gone )) && (( ! _recreated )) && (( _strikes > 0 )); then
            _classify "quay-admin-job-query-failed" "the stale-Job delete window closed after ${_strikes} failed read(s), so the delete outcome is unknown"
            echo "ERROR: ${_class_detail}"
            _dump_diagnostics
            exit 1
          fi
          if (( _recreated )); then
            echo ">>> create-admin-user Job was created by the other writer after the stale Job was deleted; adopting it"
            _install_adopted=1
            _prop "quay_admin_job_inherited" "created-concurrently"
            _job_wait=1
          elif (( ! _gone )); then
            _classify "quay-admin-job-delete-failed" "the stale create-admin-user Job is still present ${_delete_wait}s after the delete (a finalizer may be holding it); a replacement cannot be created under the same name"
            echo "ERROR: ${_class_detail}"
            _dump_diagnostics
            exit 1
          else
            echo ">>> deleted stale ${_delete_state} Job create-admin-user (admin secrets absent)"
            _prop "quay_admin_job_stale_deleted" "true"
          fi
        elif grep -qF '(NotFound)' <<<"${_delete_out}"; then
          echo ">>> create-admin-user Job was removed before the delete; creating it again"
        elif grep -qiE 'conflict|precondition' <<<"${_delete_out}"; then
          # The precondition rejected the delete, so another writer holds the
          # name: read it and take the same paths as the arms above rather than
          # failing a registry whose replacement is healthy.
          read -r _conflict_state _conflict_uid <<<"$(_quay_admin_job_snapshot)"
          if [[ "${_conflict_state}" == "query-failed" ]]; then
            _quay_admin_job_query_fail
          fi
          if [[ "${_conflict_state}" == "live" ]]; then
            _job_state="${_conflict_state}"
            _job_wait=1
            _install_adopted=1
            _prop "quay_admin_job_inherited" "live"
            echo ">>> create-admin-user Job was replaced and is live; waiting for it instead of deleting it"
          else
            _secret_state=$(_quay_admin_secrets_state)
            if [[ "${_secret_state}" == "query-failed" ]]; then
              _quay_admin_secrets_query_fail
            fi
            # Judge the Secrets against a state read taken after them, so a
            # writer that appeared during the read is seen.
            read -r _final_state _final_uid <<<"$(_quay_admin_job_snapshot)"
            if [[ "${_final_state}" == "query-failed" ]]; then
              _quay_admin_job_query_fail
            fi
            if [[ "${_final_state}" == "live" ]]; then
              _job_state="${_final_state}"
              _job_wait=1
              _install_adopted=1
              _prop "quay_admin_job_inherited" "live"
              echo ">>> create-admin-user Job was replaced and is live; waiting for it instead of deleting it"
            elif [[ "${_secret_state}" != "present" ]]; then
              if [[ "${_final_state}" == "complete" ]]; then
                _secret_state=$(_quay_admin_secrets_state)
                if [[ "${_secret_state}" == "query-failed" ]]; then
                  _quay_admin_secrets_query_fail
                fi
                if [[ "${_secret_state}" == "present" ]]; then
                  _admin_secrets=1
                  _install_adopted=1
                  _prop "quay_admin_secrets" "adopted-late"
                  _prop "quay_admin_job" "skipped-existing-secrets"
                  echo ">>> create-admin-user Job was replaced and wrote all four secrets - not touching the Job"
                else
                  _classify "quay-admin-job-replaced" "create-admin-user Job was replaced while the RBAC objects were created (observed UID ${_decided_uid:-none}, now ${_final_uid:-none}); the UID precondition rejected the delete and the replacement wrote no Secrets, so this step cannot verify the registry"
                  echo "ERROR: ${_class_detail}"
                  _dump_diagnostics
                  exit 1
                fi
              else
                if [[ "${_final_state}" == "failed" ]]; then
                  _quay_admin_job_fail
                fi
                _classify "quay-admin-job-replaced" "create-admin-user Job was replaced while the RBAC objects were created (observed UID ${_decided_uid:-none}, now ${_final_uid:-none}); the UID precondition rejected the delete and the replacement wrote no Secrets, so this step cannot verify the registry"
                echo "ERROR: ${_class_detail}"
                _dump_diagnostics
                exit 1
              fi
            elif [[ "${_final_state}" == "failed" ]]; then
              _quay_admin_job_fail
            else
              _admin_secrets=1
              _install_adopted=1
              _prop "quay_admin_secrets" "adopted-late"
              _prop "quay_admin_job" "skipped-existing-secrets"
              echo ">>> create-admin-user Job was replaced and wrote all four secrets - not touching the Job"
            fi
          fi
        else
          _classify "quay-admin-job-delete-failed" "oc delete of the stale create-admin-user Job failed ($(printf '%s' "${_delete_out}" | head -1)); the Job is left in place"
          echo "ERROR: ${_class_detail}"
          _dump_diagnostics
          exit 1
        fi
      elif (( _admin_secrets )); then
        # The Job that replaced the observed one wrote the four Secrets: nothing
        # to delete or create, and the registry check below still gates the exit.
        :
      elif (( _job_wait )); then
        # An arm above already decided to wait on the Job.
        :
      elif [[ "${_delete_state}" == "absent" ]]; then
        echo ">>> create-admin-user Job was removed while the branch was being decided; creating it again"
      else
        # A Job this step did not start is live under the name: wait for it
        # below, and mark it adopted so a rejected registry read warns instead of
        # failing a registry whose Secrets this step did not write.
        _job_state="${_delete_state}"
        _job_wait=1
        _install_adopted=1
        _prop "quay_admin_job_inherited" "live"
        echo ">>> create-admin-user Job started by another writer while the branch was being decided; waiting instead of creating"
      fi
    fi
    if (( ! _job_wait )) && (( ! _admin_secrets )); then
      _create_rc=0
      _create_out=$(cat <<'JOBEOF' | oc create -f - 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: create-admin-user
  namespace: local-quay
spec:
  # Backstop for the Job's own waits: it must not outlive the admin phase, or a
  # silent hang keeps the Job live and every later run inherits it. This is the
  # one deliberate divergence from the policy Job text. A killed Job reports
  # Failed=True with reason DeadlineExceeded, which the failure path prints, so
  # the step's own quay-admin-job-timeout class only covers a parent budget
  # shorter than this deadline.
  activeDeadlineSeconds: 360
  template:
    spec:
      containers:
        - command:
            - /bin/bash
            - -c
            - |
              #!/usr/bin/env bash
              set -euo pipefail
              set -x

              function quay_cmd() {
                DATA='{}'
                if [ -n "${4:-}" ]; then
                  DATA="${4:-}"
                fi
                # Method and path only: the request body can carry account
                # fields and the response body API payloads, and both the Job
                # log and the step's diagnostics copy are readable in
                # artifacts.
                echo "[$1] $2 $3" 1>&2
                if [ "$1" = "Basic" ]; then
                  if oc -n "${INTEROP__OPP__QUAY__NAMESPACE}" get secret "${QUAY_USER_SECRET}" -o name >/dev/null 2>&1; then
                      # BASH-7.3: the assignment traces its expanded value, so
                      # tracing is off while the credential is read.
                      set +x
                      BASIC=$(oc -n "${INTEROP__OPP__QUAY__NAMESPACE}" extract secret/${QUAY_USER_SECRET} --keys=basic --to=-)
                      set -x
                  fi
                  # The header value is a credential read by curl from a process
                  # substitution (curl -H @file), so no secret appears in the
                  # process list while curl runs.
                  curl -X "$2" $CURL_OPTS -H 'Content-Type: application/json' -H @<( set +x; printf 'Authorization: Basic %s\n' "$BASIC" ) "https://${QUAY_HOST}$3" --data "$DATA"

                elif [ "$1" = "Bearer" ]; then
                  curl -X "$2" $CURL_OPTS -H 'Content-Type: application/json' -H @<( set +x; printf 'Authorization: Bearer %s\n' "$TOKEN" ) "https://${QUAY_HOST}$3" --data "$DATA"
                else
                  curl -X "$2" $CURL_OPTS -H 'Content-Type: application/json' -H 'Fake: dummy' "https://${QUAY_HOST}$3" --data "$DATA"
                fi
                typeset -i QRC="${?}"
                if [ "${QRC}" -ne 0 ]; then
                  echo "[ERROR] $1 $2 $3 failed (curl rc=${QRC})" 1>&2
                  return "${QRC}"
                fi
                echo "[INFO] Success" 1>&2
              }

              # A required mutation. errexit is suspended where quay_cmd's
              # status is tested, so a required call needs its own check:
              # otherwise it is free to reach the final "Job finished" line
              # and report success for an organization, an application, a
              # repository or a permission that was never created. The
              # response body is discarded: nothing in it is used here, and it
              # would land in the Job log.
              function quay_required() {
                if ! quay_cmd "$@" > /dev/null; then
                  echo "[ERROR] required mutation failed: $1 $2 $3" 1>&2
                  exit 1
                fi
              }

              # A read whose result decides whether a create runs. quay_cmd
              # cannot serve that: under -f an expected 404 (the object does not
              # exist yet) and a transport, auth, or server failure all come back
              # as one nonzero status, so a failed read would collapse into the
              # same branch as a definite absence and the branch would write.
              # Prints the response body, then a final line carrying the HTTP
              # status. -s -k without -f and without -L: this is a direct
              # endpoint status probe, not a redirect-following body fetch.
              function quay_api_get() {
                curl -s -k -w '\n%{http_code}' \
                  --connect-timeout 10 --max-time 30 \
                  -H @<( set +x; printf 'Authorization: Bearer %s\n' "$TOKEN" ) "https://${QUAY_HOST}$1"
              }

              # One bounded wait, no polling loop: a loop of oc wait calls
              # reports nothing when the budget runs out and hides a hung API
              # call. The outer step already waited for Available=True, so this
              # only covers a Job re-run against a registry that regressed.
              # 300s is deliberate: it stays below the enclosing INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT
              # (default 420s), so a regressed registry surfaces as the registry diagnosis
              # rather than the job timeout; the ref-declared INTEROP__OPP__QUAY__REGISTRY_TIMEOUT
              # governs the outer step wait, not this inner re-run guard.
              echo -n "Waiting for the Quay Registry CR to be available ."
              _REG_WAIT_RC=0
              _REG_WAIT_OUT=$(oc wait QuayRegistry -n local-quay registry --for=condition=Available=true --timeout=300s 2>&1) || _REG_WAIT_RC=$?
              if [ "${_REG_WAIT_RC}" -ne 0 ]; then
                echo
                echo "[ERROR] QuayRegistry registry in local-quay did not report Available=True within 300s (oc wait rc=${_REG_WAIT_RC}): ${_REG_WAIT_OUT}" 1>&2
                exit 1
              fi
              echo "done"

              CURL_OPTS="-fsSLk --connect-timeout 10 --max-time 60"
              QUAY_ADMIN=quayadmin
              QUAY_USER=quaydevel
              QUAY_USER_SECRET="${QUAY_USER}"
              INTEROP__OPP__QUAY__NAMESPACE=local-quay
              QUAY_HOST=$(oc get route -n "${INTEROP__OPP__QUAY__NAMESPACE}" registry-quay -o jsonpath='{.spec.host}') || { echo "Quay route does not exist yet, please wait and try again."; exit 1; }
              QUAY_ORG=devel
              QUAY_ORG_EMAIL=devel@myorg.com
              QUAY_USER_EMAIL=devel-user@myorg.com
              QUAY_REPO=example
              if RESULT=$(oc get secret -n "${INTEROP__OPP__QUAY__NAMESPACE}" "${QUAY_USER_SECRET}"); then
                echo "Quay user configuration secret already exists: ${QUAY_USER_SECRET} in namespace ${INTEROP__OPP__QUAY__NAMESPACE}"
                exit 1
              fi

              # BASH-7.3: xtrace records the expanded value of an assignment, so
              # tracing is off across the whole credential window (admin password
              # generation, database initialization, all four Secrets). Otherwise
              # the generated password, the initialize body and its access_token,
              # the generated user password and both basic credentials reach the
              # Job log, which is published with the artifacts. Tracing resumes at
              # the end of the window, after the last Secret is written.
              set +x
              ADMINPASS=$(head -c 8 /dev/urandom | base64 | tr -d "=" | tr -d "\n")
              # The initialize body carries the generated admin password, so it
              # is built in an assignment and streamed on stdin: never in argv.
              typeset INIT_JSON="{ \"username\": \"quayadmin\", \"password\": \"${ADMINPASS}\", \"email\": \"quayadmin@example.com\", \"access_token\": true}"
              CURL_RC=0
              RESULT=$(printf '%s' "${INIT_JSON}" | curl -fsSLk --connect-timeout 10 --max-time 120 -X POST "https://${QUAY_HOST}/api/v1/user/initialize" --header 'Content-Type: application/json' --data @-) || CURL_RC=$?
              if [ $CURL_RC -ne 0 ]; then
                echo "Quay user initialization call failed (curl rc=${CURL_RC}); no secrets created." 1>&2
                exit 1
              fi
              if grep -q "non-empty database" <<<"$RESULT"; then
                echo "Quay user configuration failed, the database has been initialized."
                exit 1
              else
                echo "[INFO] Destroy any previous secrets ..."
                oc -n "${INTEROP__OPP__QUAY__NAMESPACE}" delete --ignore-not-found=true secret "${QUAY_USER_SECRET}"

                echo "[INFO] Creating quay admin secret quayadmin ..."
                TOKEN=$(printf '%s' "$RESULT" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                if [ -z "$TOKEN" ]; then
                  echo "[ERROR] no access_token in the initialize response; refusing to create the quayadmin secret" 1>&2
                  exit 1
                fi
                oc -n "${INTEROP__OPP__QUAY__NAMESPACE}" create secret generic quayadmin \
                  --from-file=token=<( set +x; printf '%s' "${TOKEN}" ) \
                  --from-file=password=<( set +x; printf '%s' "${ADMINPASS}" ) \
                  --from-file=basic=<(printf '%s' "${QUAY_ADMIN}:${ADMINPASS}" | base64 -w0)
                # The password-bearing body has been consumed; drop it so it
                # does not outlive its use.
                unset INIT_JSON

                echo "[INFO] Creating ${QUAY_USER} user ..."
                typeset -i URC=0
                RESPONSE=$(quay_cmd Bearer POST /api/v1/superuser/users/ "{ \"username\": \"$QUAY_USER\", \"email\": \"$QUAY_USER_EMAIL\", \"access_token\": true}") || URC=$?
                if [ "${URC}" -ne 0 ]; then
                  echo "[ERROR] failed to create Quay user ${QUAY_USER} (curl rc=${URC}); user secrets not created." 1>&2
                  exit 1
                fi

                QUAY_PASSWORD=$(printf '%s' "$RESPONSE" | jq -r '.password // empty')
                if [ -z "$QUAY_PASSWORD" ]; then
                  echo "[ERROR] superuser/users response carried no password; refusing to create ${QUAY_USER_SECRET}" 1>&2
                  exit 1
                fi
                BASE64AUTH=$(printf '%s' "${QUAY_USER}:${QUAY_PASSWORD}" | base64 -w0)

                echo "[INFO] Creating ${QUAY_USER_SECRET} secret ..."
                # Secret values arrive on their own streams, never in argv
                # (process listings and the Job manifest's command line are
                # readable in artifacts). Two keys cannot both read stdin, so
                # each gets its own process-substitution stream, byte-exact:
                # same form as the quayadmin secret above.
                oc -n "${INTEROP__OPP__QUAY__NAMESPACE}" create secret generic "${QUAY_USER_SECRET}" \
                  --from-file=password=<( set +x; printf '%s' "${QUAY_PASSWORD}" ) \
                  --from-file=basic=<( set +x; printf '%s' "${BASE64AUTH}" )

                echo "[INFO] Creating quay-pull-secret ..."
                printf '%s' "{ \"auths\": { \"$QUAY_HOST\": { \"auth\": \"$BASE64AUTH\" } }}" | oc -n "${INTEROP__OPP__QUAY__NAMESPACE}" create secret generic quay-pull-secret --from-file=.dockerconfigjson=/dev/stdin --type=kubernetes.io/dockerconfigjson

                echo "[INFO] Creating quay integration token secret ..."
                oc -n "${INTEROP__OPP__QUAY__NAMESPACE}" create secret generic quay-integration \
                  --from-file=token=<( set +x; printf '%s' "${TOKEN}" )
                # End of the credential window: every Secret holding a credential
                # is written, so control flow below is traced again.
                set -x
              fi

              echo "[INFO] Looking for initial organization ..."
              _ORG_READ="$(quay_api_get "/api/v1/organization/${QUAY_ORG}")"
              _ORG_STATUS="${_ORG_READ##*$'\n'}"
              _ORG_BODY="${_ORG_READ%$'\n'*}"
              _ORG_ABSENT=0
              case "${_ORG_STATUS}" in
                2[0-9][0-9])
                  # A successful read that still says not_found is a definite
                  # absence; any other successful body means the org is there.
                  if grep -q not_found <<<"${_ORG_BODY}"; then
                    _ORG_ABSENT=1
                  fi
                  ;;
                404)
                  _ORG_ABSENT=1
                  ;;
                *)
                  echo "[ERROR] GET organization ${QUAY_ORG} failed (HTTP ${_ORG_STATUS:-no response}); refusing to create it" 1>&2
                  exit 1
                  ;;
              esac
              if [ "${_ORG_ABSENT}" -eq 1 ]; then
                echo "[INFO] Creating ${QUAY_ORG} org ..."
                # Email cannot be shared with the initial user
                quay_required Bearer POST /api/v1/organization/ "{\"name\": \"$QUAY_ORG\", \"email\": \"$QUAY_ORG_EMAIL\" }"
                quay_cmd Basic GET /api/v1/organization/$QUAY_ORG > /dev/null
              fi

              echo "[INFO] Looking for org application ..."
              # The only way to get another OAuth token is to go to: Organization -> Applications -> {app} -> Generate Token
              # If there was a programatic way to do it here, we could avoid the problem with the bearer token expiring after 150min
              APPLICATION=automation
              # The applications response carries the automation app's
              # client_secret: app_view decrypts it for an org admin, and this
              # request runs as one. Tracing stays off from the read through the
              # count (the printf argument is the whole body) so the secret cannot
              # reach the Job log; it resumes before the create decision, whose
              # command carries no secret.
              set +x
              _APPS_READ="$(quay_api_get "/api/v1/organization/${QUAY_ORG}/applications")"
              _APPS_STATUS="${_APPS_READ##*$'\n'}"
              _APPS_BODY="${_APPS_READ%$'\n'*}"
              if [ "${_APPS_STATUS}" != "200" ]; then
                echo "[ERROR] GET applications for ${QUAY_ORG} failed (HTTP ${_APPS_STATUS:-no response}); refusing to create ${APPLICATION}" 1>&2
                exit 1
              fi
              COUNT="$(printf '%s' "${_APPS_BODY}" | jq --arg app "${APPLICATION}" '[.applications[] | select(.name == $app)] | length')"
              set -x
              if [ "${COUNT}" -eq 0 ]; then
                echo "[INFO] Creating ${APPLICATION} application..."
                quay_required Bearer POST /api/v1/organization/$QUAY_ORG/applications "{\"name\": \"$QUAY_ORG-automation\", \"description\": \"automation app\" }"
              fi

              echo "[INFO] Looking for initial repo ..."
              _REPO_READ="$(quay_api_get "/api/v1/repository/${QUAY_ORG}/${QUAY_REPO}")"
              _REPO_STATUS="${_REPO_READ##*$'\n'}"
              _REPO_BODY="${_REPO_READ%$'\n'*}"
              _REPO_ABSENT=0
              case "${_REPO_STATUS}" in
                2[0-9][0-9])
                  if grep -q not_found <<<"${_REPO_BODY}"; then
                    _REPO_ABSENT=1
                  fi
                  ;;
                404)
                  _REPO_ABSENT=1
                  ;;
                *)
                  echo "[ERROR] GET repository ${QUAY_ORG}/${QUAY_REPO} failed (HTTP ${_REPO_STATUS:-no response}); refusing to create it" 1>&2
                  exit 1
                  ;;
              esac
              if [ "${_REPO_ABSENT}" -eq 1 ]; then
                echo "[INFO] Creating ${QUAY_REPO} repo..."
                quay_required Bearer POST /api/v1/repository "{\"namespace\":\"$QUAY_ORG\", \"repository\":\"$QUAY_REPO\", \"visibility\":\"public\", \"description\":\"Development Repo\", \"repo_kind\":\"image\"}"
              fi

              echo "[INFO] Looking for ${QUAY_ORG} members ..."
              _MEMB_READ="$(quay_api_get "/api/v1/organization/${QUAY_ORG}/team/owners/members")"
              _MEMB_STATUS="${_MEMB_READ##*$'\n'}"
              _MEMB_BODY="${_MEMB_READ%$'\n'*}"
              if [ "${_MEMB_STATUS}" != "200" ]; then
                echo "[ERROR] GET owners team members for ${QUAY_ORG} failed (HTTP ${_MEMB_STATUS:-no response}); refusing to add ${QUAY_USER}" 1>&2
                exit 1
              fi
              COUNT="$(printf '%s' "${_MEMB_BODY}" | jq --arg user "${QUAY_USER}" '[.members[]? | select(.name == $user)] | length')"
              if [ "${COUNT}" -eq 0 ]; then
                echo "[INFO] Associating ${QUAY_USER} with ${QUAY_ORG} ..."
                quay_required Bearer PUT /api/v1/organization/$QUAY_ORG/team/owners/members/$QUAY_USER '{}'
              fi

              echo "[INFO] Looking for ${QUAY_REPO} admins ..."
              _ADMIN_READ="$(quay_api_get "/api/v1/repository/${QUAY_ORG}/${QUAY_REPO}/permissions/user/${QUAY_USER}")"
              _ADMIN_STATUS="${_ADMIN_READ##*$'\n'}"
              _ADMIN_BODY="${_ADMIN_READ%$'\n'*}"
              case "${_ADMIN_STATUS}" in
                200)
                  # GET /repository/<repo>/permissions/user/<user> answers one flat
                  # permission object ({"role": "admin", "name": "<user>"}), not a
                  # .permissions collection: read the role off the object itself,
                  # and stay tolerant of a list-shaped body so an answer shape
                  # change cannot turn "already admin" into "grant it again".
                  COUNT="$(printf '%s' "${_ADMIN_BODY}" | jq '[.role, (.permissions[]?.role)] | map(select(. == "admin")) | length')"
                  ;;
                404)
                  # No permission row for this user yet: a definite negative.
                  COUNT=0
                  ;;
                *)
                  echo "[ERROR] GET repository permission for ${QUAY_USER} failed (HTTP ${_ADMIN_STATUS:-no response}); refusing to grant admin" 1>&2
                  exit 1
                  ;;
              esac
              if [ "${COUNT}" -eq 0 ]; then
                echo "[INFO] Give ${QUAY_USER} admin rights to the repo ..."
                quay_required Bearer PUT /api/v1/repository/$QUAY_ORG/$QUAY_REPO/permissions/user/$QUAY_USER '{ "role": "admin"}'
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
      ) || _create_rc=$?
      if (( _create_rc != 0 )); then
        # A live OperatorPolicy may create the same Job between the state read
        # above and this create: adopt that one instead of exiting unclassified.
        if grep -qiE 'already ?exists' <<<"${_create_out}"; then
          echo ">>> create-admin-user Job was created by the other writer between the state read and this create; adopting it"
          _install_adopted=1
          _prop "quay_admin_job_inherited" "created-concurrently"
        else
          echo "${_create_out}"
          _classify "quay-admin-job-create-failed" "oc create of the create-admin-user Job failed; no Job is running"
          echo "ERROR: ${_class_detail}"
          _dump_diagnostics
          exit 1
        fi
      else
        echo "${_create_out}"
      fi
      _job_wait=1
    fi
  fi
  if (( _job_wait )); then
    # Wait for Complete OR Failed: oc wait --for=condition=Complete never returns
    # on a failed Job, so it burned the full timeout and then classified from
    # .status.failed == 1 (wrong as soon as the default backoffLimit of 6 yields
    # more than one failed pod). The Failed condition is the terminal signal;
    # .status.failed is diagnostic detail only. The state helper separates
    # absence from an API error, so a Job that cannot be read is reported as
    # quay-admin-job-query-failed instead of burning the whole timeout.
    # The verification below the wait is charged against the same deadline: cap
    # the wait deadline so the Secret re-read and the registry checks still fit
    # inside it (a cap, not a subtraction from the configured timeout, so a short
    # INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT still gets its full value when the budget allows).
    _job_started=$(date +%s)
    _job_deadline=$(_clamp_deadline $(( _job_started + INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT )))
    _verify_cap=$(( _work_deadline - _diag_reserve - _oc_overrun_reserve - _verify_reserve ))
    if (( _job_deadline > _verify_cap )); then _job_deadline=${_verify_cap}; fi
    if (( _job_deadline <= $(date +%s) )); then _job_deadline=$(( $(date +%s) + 1 )); fi
    _job_state=""
    while :; do
      _job_state=$(_quay_admin_job_state)
      case "${_job_state}" in
        complete|failed) break ;;
        query-failed) _quay_admin_job_query_fail ;;
        absent)
          _classify "quay-admin-job-deleted" "create-admin-user Job disappeared while the step was waiting for it"
          echo "ERROR: ${_class_detail}"
          _dump_diagnostics
          exit 1
          ;;
      esac
      _job_left=$(( _job_deadline - $(date +%s) ))
      if (( _job_left <= 0 )); then _job_state="timeout"; break; fi
      if (( _job_left < _po_poll_interval )); then sleep "${_job_left}"; else sleep "${_po_poll_interval}"; fi
    done
    _job_waited=$(( $(date +%s) - _job_started ))
    _prop "quay_admin_job_state" "${_job_state}"
    if [[ "${_job_state}" == "failed" ]]; then
      _quay_admin_job_fail
    fi
    if [[ "${_job_state}" != "complete" ]]; then
      _job_failed=$(oc get job create-admin-user -n "${INTEROP__OPP__QUAY__NAMESPACE}" -o jsonpath='{.status.failed}') || _job_failed=""
      echo ">>> DIAG: create-admin-user Job logs (tail 200):"
      _quay_admin_log || true
      _classify "quay-admin-job-timeout" "create-admin-user Job neither Complete nor Failed within ${_job_waited}s (INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT=${INTEROP__OPP__QUAY__ADMIN_JOB_TIMEOUT}s, capped by the verification reserve; failed pods=${_job_failed:-none})"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
    _secret_state=$(_quay_admin_secrets_state)
    if [[ "${_secret_state}" == "query-failed" ]]; then
      _quay_admin_secrets_query_fail
    fi
    if [[ "${_secret_state}" != "present" ]]; then
      echo ">>> DIAG: create-admin-user Job logs (tail 200):"
      _quay_admin_log || true
      _classify "quay-admin-secrets-missing" "Job create-admin-user completed but quayadmin/quaydevel/quay-pull-secret/quay-integration are not all present"
      echo "ERROR: ${_class_detail}"
      _dump_diagnostics
      exit 1
    fi
    _prop "quay_admin_job" "completed"
    if (( ${_install_adopted:-0} )); then
      # The Job that produced them was inherited, so this step wrote neither.
      _prop "quay_admin_secrets" "present"
    else
      _prop "quay_admin_secrets" "created"
    fi
  fi
fi

_quay_org_repo_check

for _s in quayadmin quaydevel quay-pull-secret quay-integration; do
  _prop "secret_${_s//-/_}" "present"
done

_prop "quay_deployed" "true"
echo ">>> PHASE: Quay deployed (operator + registry + admin secrets)"
true
