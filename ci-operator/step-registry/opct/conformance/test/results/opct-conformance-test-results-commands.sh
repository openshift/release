#!/bin/bash

#
# Extract the results from the test environment (aggregator server).
#

set -o nounset
set -o errexit
set -o pipefail

declare -gx RESULT_FILE
export KUBECONFIG=${SHARED_DIR}/kubeconfig

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
extract_opct

# --- Gated OPCT checks (const) ----------------------------------------------
# Checks that gate the job. These are OPCT's own execution-validity checks,
# read from the report rather than recomputed here, so CI inherits OPCT's
# definition of a broken run instead of duplicating the logic.
# Per OPCT maintainer direction, Slack G012C6LKVM2/p1795182222655659.
#
#   OPCT-022  "Detected one or more plugin(s) with potential invalid result"
#             internal/report/slo.go. Mode-aware: checks plugins 05+99 in
#             upgrade mode, 10+20+99 otherwise. Fails when a plugin has
#             Stat.Total == Stat.Failed (every result a failure, i.e. the
#             suite never really ran) or when an expected plugin is absent
#             from the report entirely (crashed before emitting a summary).
#   OPCT-023A "Sanity [10-openshift-kube-conformance]: potential missing
#             tests in suite" -- plugin 10 must report more than 300 tests.
#   OPCT-023B "Sanity [20-openshift-conformance-validated]: potential
#             missing tests in suite" -- plugin 20 must report more than
#             3000 tests.
#
# 023A/023B report "skip" in upgrade mode, where those plugins do not run,
# so they never produce a false positive there.
#
# The set is deliberately explicit. Most OPCT checks describe cluster
# quality rather than execution validity and fail routinely on healthy runs
# -- OPCT-010A/010B (etcd slow-request latency) fail on nearly every run
# observed, including clean ones -- so gating on "any failed check" would
# red every job.
GATED_CHECK_IDS=("OPCT-022" "OPCT-023A" "OPCT-023B")

# --- Return-code accounting ------------------------------------------------
# Each processing stage gets a dedicated variable initialised to NOT_RUN so
# that an unexecuted stage is never confused with exit-code 0.  Raw codes
# from each command are preserved exactly as returned and reported in the
# structured summary.
retrieve_rc="NOT_RUN"
retrieve_tee_rc="NOT_RUN"
retrieve_pipe_rc="NOT_RUN"
# retrieve_reason names which of retrieve_artifact's failure paths was taken,
# so the JUnit testcase reports the actual cause instead of one generic
# message. Two of the four paths leave both retrieve rcs at 0 (the archive is
# missing or ambiguous rather than the command having failed), which the exit
# codes alone cannot distinguish.
#   retrieve_failed    = 'opct retrieve' itself exited nonzero
#   tee_failed         = retrieve succeeded, the tee pipeline did not
#   no_archive         = no *.tar* produced in the results directory
#   multiple_archives  = more than one *.tar*, cannot pick one safely
retrieve_reason="NOT_RUN"
results_rc="NOT_RUN"
report_rc="NOT_RUN"
publish_rc="NOT_RUN"
# publish_reason classifies a nonzero publish_rc as either:
#   rejected          = OPCT's own SLO checks declined the baseline (not an
#                        infra/processing failure -- see publish step below)
#   processing_error  = genuine infra/processing failure (e.g. S3 upload)
publish_reason="NOT_RUN"
indexer_rc="NOT_RUN"

# check_runtime_gate return contract:
#   0 = none of the gated OPCT checks failed
#   1 = at least one gated check failed (runtime failure)
#   2 = report missing or malformed (processing problem)
runtime_gate_rc="NOT_RUN"
runtime_gate_reason=""

# Exit classes:
#   0 = success (all stages passed)
#   1 = runtime_failure (a gated OPCT check reported a failed execution)
#   2 = processing_failure (infrastructure/processing error)
#   3 = both (runtime failure AND processing failure)
exit_class=0

# Set by _signal_handler when a signal is caught.
_caught_signal=""

# --- JUnit reporting -------------------------------------------------------
# Prow auto-discovers junit*.xml under ARTIFACT_DIR and renders each testcase
# in Spyglass, so the reviewer sees which stage broke without reading the raw
# step log.
#
# Scope is deliberately limited to this step's own runtime stages and the
# OPCT checks gated below. Individual conformance test results are NOT
# emitted here: a testcase carrying a <failure> is a real failed test to
# Prow/sippy/TRT and would inject e2e conformance failures -- which are OCP
# engineering's to fix, not this job's verdict -- into flake tracking.
# Conformance detail stays in opct-report.json (uploaded as an artifact).
# Per OPCT maintainer direction, Slack G012C6LKVM2/p1795183372863719.
JUNIT_CASES_FILE="/tmp/opct-junit-cases.xml"
: >"${JUNIT_CASES_FILE}"
junit_tests=0
junit_failures=0

# xml_escape escapes the five XML predefined entities. Error text reaches
# the XML body verbatim and routinely contains jq output, JSON fragments and
# paths, so an unescaped '<' or '&' would make the whole file unparseable and
# silently drop the report.
function xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# junit_case records one testcase. With a second argument the case is a
# failure carrying that message; without one it passed.
function junit_case() {
  local name="$1"
  local failure_msg="${2:-}"
  junit_tests=$((junit_tests + 1))
  {
    printf '  <testcase name="%s" classname="opct-conformance-test-results">\n' "$(xml_escape "${name}")"
    if [[ -n "${failure_msg}" ]]; then
      junit_failures=$((junit_failures + 1))
      printf '    <failure message="">%s</failure>\n' "$(xml_escape "${failure_msg}")"
    fi
    printf '  </testcase>\n'
  } >>"${JUNIT_CASES_FILE}"
}

# junit_skip records a stage that never executed, so the testcase-name set
# stays stable across runs and run modes (upgrade jobs skip several stages).
function junit_skip() {
  local name="$1"
  local reason="${2:-not executed}"
  junit_tests=$((junit_tests + 1))
  {
    printf '  <testcase name="%s" classname="opct-conformance-test-results">\n' "$(xml_escape "${name}")"
    printf '    <skipped message="%s"/>\n' "$(xml_escape "${reason}")"
    printf '  </testcase>\n'
  } >>"${JUNIT_CASES_FILE}"
}

# emit_junit wraps the accumulated testcases in a testsuite element. Called
# from the EXIT trap so the file is written on every path, including early
# returns and the signal handler.
junit_emitted=""
function emit_junit() {
  [[ -n "${junit_emitted}" ]] && return 0
  junit_emitted=1
  [[ -n "${ARTIFACT_DIR:-}" ]] || return 0
  [[ -s "${JUNIT_CASES_FILE}" ]] || return 0

  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="OPCT results processing" tests="%d" failures="%d" errors="0" time="%d">\n' \
      "${junit_tests}" "${junit_failures}" "${SECONDS}"
    cat "${JUNIT_CASES_FILE}"
    printf '</testsuite>\n'
  } >"${ARTIFACT_DIR}/junit_opct_results.xml" 2>/dev/null \
    || show_msg "WARNING: failed to write ${ARTIFACT_DIR}/junit_opct_results.xml"
}

# emit_summary writes the structured summary block to both console and
# ARTIFACT_DIR (durable).  It is called in the normal flow and from the
# EXIT trap so it always appears.  Values that may contain whitespace or
# special characters are quoted to keep the block unambiguous.
summary_emitted=""
function emit_summary() {
  [[ -n "${summary_emitted}" ]] && return
  summary_emitted=1

  # Quote runtime_gate_reason: replace newlines and single-quotes so the
  # block stays parseable as a simple key=value list.
  local safe_reason="${runtime_gate_reason//$'\n'/ }"
  safe_reason="${safe_reason//\'/\'\\\'\'}"

  # Build raw_status and raw_reason for unexpected/signal conditions.
  local raw_status=""
  local raw_reason=""
  if [[ -n "${_caught_signal}" ]]; then
    case "${_caught_signal}" in
      TERM) raw_status="143" ;;
      INT)  raw_status="130" ;;
      *)    raw_status="signal-${_caught_signal}" ;;
    esac
    raw_reason="caught SIG${_caught_signal}"
  elif [[ ${exit_class} -ne 0 && -z "${runtime_gate_reason}" && "${runtime_gate_rc}" == "0" ]]; then
    raw_status="late-failure"
    raw_reason="exit_class set to ${exit_class} after passing gate"
  fi

  local block
  block=$(cat <<EOS

#>> OPCT_RESULTS_SUMMARY
retrieve_rc=${retrieve_rc}
retrieve_tee_rc=${retrieve_tee_rc}
retrieve_pipe_rc=${retrieve_pipe_rc}
retrieve_reason=${retrieve_reason}
results_rc=${results_rc}
report_rc=${report_rc}
publish_rc=${publish_rc}
publish_reason=${publish_reason}
indexer_rc=${indexer_rc}
runtime_gate_rc=${runtime_gate_rc}
runtime_gate_reason='${safe_reason}'
exit_class=${exit_class}
caught_signal=${_caught_signal:-none}
raw_status=${raw_status:-normal}
raw_reason='${raw_reason}'
#<< OPCT_RESULTS_SUMMARY
EOS
)
  echo "${block}"
  # Write to durable artifact.  If the write fails, the console output
  # above still provides the outcome.
  if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    if ! echo "${block}" > "${ARTIFACT_DIR}/opct-results-summary.txt" 2>/dev/null; then
      show_msg "WARNING: failed to write summary to ${ARTIFACT_DIR}/opct-results-summary.txt"
    fi
  fi
}

# Signal handler: records that a signal was caught and forces a processing
# failure.  The EXIT trap (_exit_handler) then runs for cleanup.
function _signal_handler() {
  local sig="${1:-UNKNOWN}"
  _caught_signal="${sig}"
  exit_class=$((exit_class | 2))
  # Map signal name to correct exit code (128 + signal number).
  local sig_exit=143  # default: SIGTERM = 128 + 15
  case "${sig}" in
    INT)  sig_exit=130 ;;  # 128 + 2
    TERM) sig_exit=143 ;;  # 128 + 15
  esac
  # exit triggers the EXIT trap which does emit_summary + dump.
  exit ${sig_exit}
}
trap '_signal_handler TERM' TERM
trap '_signal_handler INT' INT

# EXIT handler: emits the summary and runs diagnostics.  If exit_class is
# still 0 but we are exiting nonzero, a late processing error occurred
# (e.g. mv failure after the gate passed).  Namespace dump runs here at
# exit time, not earlier.
function _exit_handler() {
  local incoming_rc=$?
  if [[ ${exit_class} -eq 0 && ${incoming_rc} -ne 0 ]]; then
    exit_class=2
  fi
  emit_summary || true
  # Catch-all: the step is failing but no stage recorded a failing testcase,
  # so the Prow test view would show nothing red while the job is red. This
  # happens on paths that abort outside a guarded stage -- an errexit abort
  # (e.g. the 'mv' of the result archive), a setup failure before the first
  # stage, or a signal caught mid-stage. Emit one testcase carrying the exit
  # class so the failure is always visible as a test, not only as an exit
  # code.
  if [[ ${exit_class} -ne 0 && ${junit_failures} -eq 0 ]]; then
    junit_case "[opct] results step completed" \
      "the step failed with exit_class=${exit_class} (incoming_rc=${incoming_rc}, signal=${_caught_signal:-none}) but no stage reported a failure; see opct-results-summary.txt and the step log"
  fi
  # Written here rather than in the main flow so the report still lands on
  # early-return and signal paths.
  emit_junit || true
  # Namespace dump is best-effort; its failure must not change the
  # original exit_class outcome.  The shared dump_opct_namespace helper
  # (from opct-pre-init) captures rc=$? and calls 'exit $rc'.  Two
  # isolation issues arise if it runs directly in this handler:
  #   1. emit_summary resets $? to 0, so the helper always sees rc=0
  #      and skips the namespace inspection even on error paths.
  #   2. The helper's 'exit $rc' terminates the process before this
  #      handler reaches 'exit ${exit_class}', overriding the intended
  #      exit code.
  # Running in a subshell solves both: '(exit N)' seeds $? with
  # exit_class so the helper sees the correct error state, and the
  # helper's 'exit' terminates only the subshell.
  ( (exit ${exit_class}); dump_opct_namespace ) || true
  exit ${exit_class}
}
trap '_exit_handler' EXIT

function show_reader() {
  echo "#>>
# $*
#<<"
}

function collect_inspect() {
  show_reader "Inspecting Namespace 'opct'"
  inspect_root_dir=/tmp/inspect-ns-opct
  mkdir -p ${inspect_root_dir}
  oc adm inspect ns/opct --dest-dir=${inspect_root_dir}
  tar cfz "${ARTIFACT_DIR}"/inspect-opct.tar.gz ${inspect_root_dir}
}

function retrieve_artifact() {
  # Retrieve after successful execution.
  # Explicit return-code checks are required because this function is called
  # inside 'if !', which disables errexit for the entire function body.
  show_reader "Retrieving Results"
  show_msg "\t>> running: ${OPCT_CLI} retrieve\n"
  mkdir -p "${ARTIFACT_DIR}/opct-results"

  # Capture all pipeline component exit codes immediately after the
  # pipeline statement.  PIPESTATUS must be read on the very next line;
  # any intervening command (including '|| true') resets it.
  # Under pipefail, $? is the rightmost nonzero or 0 if all succeed.
  # stderr is merged into the pipeline so that a shell-level failure (missing
  # binary, OOM kill) still leaves its reason in log-retrieve.txt, which the
  # JUnit failure body tails. tee keeps it on the console as well.
  ${OPCT_CLI} retrieve "${ARTIFACT_DIR}/opct-results" 2>&1 | tee -a "${ARTIFACT_DIR}"/log-retrieve.txt
  local -a ps=("${PIPESTATUS[@]}")
  retrieve_rc=${ps[0]:-1}
  retrieve_tee_rc=${ps[1]:-1}

  # Reconstruct pipefail semantics: rightmost nonzero, or 0 if all succeed.
  if [[ ${retrieve_tee_rc} -ne 0 ]]; then
    retrieve_pipe_rc=${retrieve_tee_rc}
  else
    retrieve_pipe_rc=${retrieve_rc}
  fi

  if [[ ${retrieve_rc} -ne 0 ]]; then
    retrieve_reason="retrieve_failed"
    show_msg "ERROR: '${OPCT_CLI} retrieve' failed with exit code ${retrieve_rc} (tee=${retrieve_tee_rc})"
    return 1
  fi

  # tee failure is a processing error (log may be incomplete) even if
  # retrieve itself succeeded.
  if [[ ${retrieve_tee_rc} -ne 0 ]]; then
    retrieve_reason="tee_failed"
    show_msg "ERROR: tee pipeline failed with exit code ${retrieve_tee_rc} (retrieve=${retrieve_rc})"
    return 1
  fi

  # Identify the single result archive.  Glob into an array to detect
  # missing or ambiguous results without relying on ls output parsing.
  local -a archives=("${ARTIFACT_DIR}"/opct-results/*.tar*)
  if [[ ${#archives[@]} -eq 0 || ! -f "${archives[0]}" ]]; then
    retrieve_reason="no_archive"
    show_msg "ERROR: no result archive found in ${ARTIFACT_DIR}/opct-results/"
    return 1
  fi
  if [[ ${#archives[@]} -gt 1 ]]; then
    retrieve_reason="multiple_archives"
    show_msg "ERROR: multiple result archives found in ${ARTIFACT_DIR}/opct-results/ (${#archives[@]} files)"
    return 1
  fi
  retrieve_reason="ok"
  RESULT_FILE="${archives[0]}"
}

function show_results() {
  show_reader "Exporting Results"

  # Run results summary (to log to file).
  # Explicit return-code checks are required because this function is called
  # inside 'if !', which disables errexit for the entire function body.
  show_msg "\t>> running: ${OPCT_CLI} results\n"
  local rc=0
  # stderr is merged so a shell-level failure (missing binary, OOM kill) still
  # leaves its reason in the log the JUnit failure body tails.
  ${OPCT_CLI} results "${RESULT_FILE}" > "${ARTIFACT_DIR}"/log-results.txt 2>&1 || rc=$?
  results_rc=${rc}
  if [[ ${rc} -ne 0 ]]; then
    show_msg "ERROR: '${OPCT_CLI} results' exited with code ${rc}"
    return ${rc}
  fi

  # Run report (to log to file)
  show_msg "\n\t>> running: ${OPCT_CLI} report\n"
  rc=0
  ${OPCT_CLI} report \
    --skip-server \
    --log-level=debug \
    --save-to "${ARTIFACT_DIR}"/opct-report \
    "${RESULT_FILE}" > "${ARTIFACT_DIR}"/log-report.txt 2>&1 || rc=$?
  report_rc=${rc}
  if [[ ${rc} -ne 0 ]]; then
    show_msg "ERROR: '${OPCT_CLI} report' exited with code ${rc}"
    return ${rc}
  fi
}

# The gated check set (GATED_CHECK_IDS) is declared at the top of the
# script next to the other constants; see there for why each check is
# included and why the set is explicit rather than "any failed check".

# check_runtime_gate fails the job when OPCT reports that a plugin did not
# execute validly. Conformance test outcomes are deliberately NOT gated:
# a surviving e2e failure is OCP engineering's to fix and gives the OPCT
# job reviewer nothing to act on, so it stays in opct-report.json rather
# than reding CI. Per OPCT maintainer direction, Slack
# G012C6LKVM2/p1795173987516569.
#
# Return values (contract):
#   0 = no gated check failed
#   1 = at least one gated check failed (runtime failure)
#   2 = report missing or malformed (processing problem)
#
# The caller must capture the return value directly; using 'if !' would
# lose the distinction between 1 and 2.
function check_runtime_gate() {
  show_reader "Checking OPCT execution-validity checks"

  local report_json="${ARTIFACT_DIR}/opct-report/opct-report.json"
  if [[ ! -f "${report_json}" ]]; then
    runtime_gate_reason="opct-report.json missing at ${report_json}"
    show_msg "ERROR: ${runtime_gate_reason}"
    junit_case "[opct] OPCT execution-validity checks" "${runtime_gate_reason}"
    return 2
  fi

  # .checks.failures holds the checks that evaluated to "fail". Parse with
  # jq from the 'upi-installer' image (already a base_images dependency of
  # every consuming config) because it ships jq, unlike the base 'cli'.
  local failed_ids
  failed_ids=$(jq -e -r '
    .checks.failures
    | if type != "array" then error("checks.failures is not an array: \(type)") else . end
    | map(.id)
    | join(" ")
  ' "${report_json}" 2>&1) || {
    runtime_gate_reason="failed to parse checks.failures from ${report_json}: ${failed_ids}"
    show_msg "ERROR: ${runtime_gate_reason}"
    junit_case "[opct] OPCT execution-validity checks" "${runtime_gate_reason}"
    return 2
  }

  show_msg "Failed OPCT checks (all): ${failed_ids:-none}"
  show_msg "Checks gating this job: ${GATED_CHECK_IDS[*]}"

  local gated_hits=()
  local id
  for id in "${GATED_CHECK_IDS[@]}"; do
    # Match on whole words so e.g. OPCT-023A cannot satisfy OPCT-023.
    if [[ " ${failed_ids} " == *" ${id} "* ]]; then
      gated_hits+=("${id}")
    fi
  done

  if [[ ${#gated_hits[@]} -ne 0 ]]; then
    runtime_gate_reason="OPCT reported invalid plugin execution; failed check(s): ${gated_hits[*]}"
    show_msg "ERROR: Runtime gate FAILED: ${runtime_gate_reason}"
    local check_slo check_doc check_json check_body
    for id in "${gated_hits[@]}"; do
      # Reuse the check's own metadata from the report -- .slo (human
      # description) and .documentation (rules URL) -- so the JUnit testcase
      # is self-describing in Spyglass without opening opct-report.json.
      # Per OPCT maintainer review, PR 87541 r4649973721.
      IFS=$'\t' read -r check_slo check_doc check_json < <(jq -r --arg id "${id}" '
        [.checks.failures[] | select(.id == $id)][0]
        | [(.slo // ""), (.documentation // ""), (tojson)]
        | @tsv
      ' "${report_json}" 2>/dev/null) || true
      [[ -z "${check_slo:-}" ]] && check_slo="${id}"
      check_body="${check_json:-${id} failed}"
      if [[ -n "${check_doc}" ]]; then
        check_body+=$'\n'"see test documentation ${check_doc}, opct-report.json (.checks.failures) and the plugin logs"
      else
        check_body+=$'\n'"see opct-report.json (.checks.failures) and the plugin logs"
      fi
      junit_case "[opct] check ${id} - ${check_slo}" "${check_body}"
    done
    junit_case "[opct] OPCT execution-validity checks" "${runtime_gate_reason}"
    return 1
  fi

  show_msg "Runtime gate passed: none of ${GATED_CHECK_IDS[*]} failed"
  junit_case "[opct] OPCT execution-validity checks"
  return 0
}

function extract_container_logs() {
  show_reader "Extracting container logs from OPCT archive"
  local container_logs_dir="${ARTIFACT_DIR}/container-logs"
  mkdir -p "${container_logs_dir}"

  if [[ -z "${RESULT_FILE:-}" ]]; then
    show_msg "# WARNING: RESULT_FILE is not set, skipping container log extraction."
    return 0
  fi

  # Extract podlogs from the OPCT archive to a temporary directory.
  local tmp_podlogs="/tmp/opct-podlogs"
  mkdir -p "${tmp_podlogs}"
  tar xvf "${RESULT_FILE}" -C "${tmp_podlogs}" --wildcards '*podlogs/*/logs/tests.txt' 2>/dev/null || true

  # Copy each tests.txt log file, using the pod directory name as a prefix
  # to distinguish between multiple conformance pods.
  find "${tmp_podlogs}" -name 'tests.txt' -path '*podlogs/*/logs/*' | while read -r logfile; do
    local pod_dir
    pod_dir=$(basename "$(dirname "$(dirname "${logfile}")")")
    cp -v "${logfile}" "${container_logs_dir}/${pod_dir}-tests.txt"
  done

  local log_count
  log_count=$(find "${container_logs_dir}" -name '*-tests.txt' 2>/dev/null | wc -l)
  show_msg "Extracted ${log_count} container log(s) to ${container_logs_dir}"

  # Redact potentially sensitive data from extracted logs, following the
  # same patterns used by other CI steps (e.g. baremetalds-devscripts-gather).
  if [[ ${log_count} -gt 0 ]]; then
    find "${container_logs_dir}" -name '*-tests.txt' -exec sed -i '
      /auths/ s/.*/*** PULL_SECRET ***/;
      s/password: .*/password: REDACTED/;
      s/password=.*/password=REDACTED/;
      s/token: .*/token: REDACTED/;
      s/token=.*/token=REDACTED/;
      s/X-Auth-Token.*/X-Auth-Token REDACTED/;
      s/Bearer .*/Bearer REDACTED/;
      s/UserData:.*,/UserData: REDACTED,/;
      ' {} +
    show_msg "Redacted sensitive patterns from extracted logs"
  fi

  rm -rf "${tmp_podlogs}"
}

# ===== Main flow ============================================================

# Diagnostic-only: namespace inspection (best-effort).
collect_inspect || true

# Required: retrieve the result archive from the aggregator.
if ! retrieve_artifact; then
  show_msg "ERROR: Failed to retrieve result artifact."
  # retrieve_rc / retrieve_tee_rc / retrieve_pipe_rc were set inside retrieve_artifact
  exit_class=$((exit_class | 2))
  # retrieve_artifact fails for four distinct reasons; two of them leave both
  # exit codes at 0 (the archive is missing or ambiguous rather than the
  # command having failed), so retrieve_reason names the actual cause.
  case "${retrieve_reason}" in
    retrieve_failed)
      retrieve_detail="'${OPCT_CLI} retrieve' exited with code ${retrieve_rc} (tee_rc=${retrieve_tee_rc})" ;;
    tee_failed)
      retrieve_detail="the tee pipeline exited with code ${retrieve_tee_rc}, so log-retrieve.txt may be incomplete ('${OPCT_CLI} retrieve' itself returned ${retrieve_rc})" ;;
    no_archive)
      retrieve_detail="'${OPCT_CLI} retrieve' returned ${retrieve_rc} but produced no result archive in ${ARTIFACT_DIR}/opct-results/" ;;
    multiple_archives)
      retrieve_detail="more than one result archive found in ${ARTIFACT_DIR}/opct-results/; cannot choose one safely" ;;
    *)
      retrieve_detail="failed to retrieve a single result archive (retrieve_rc=${retrieve_rc}, tee_rc=${retrieve_tee_rc})" ;;
  esac
  junit_case "[opct] retrieve result archive" \
    "${retrieve_detail}
$(tail -n 5 "${ARTIFACT_DIR}/log-retrieve.txt" 2>/dev/null)
see log-retrieve.txt and the errors above"
else
  junit_case "[opct] retrieve result archive"
fi

# Required: generate results summary and report.
# Only attempt if retrieval succeeded (RESULT_FILE is set).
if [[ -n "${RESULT_FILE:-}" ]]; then
  if ! show_results; then
    show_msg "ERROR: Failed to generate results summary or report."
    # results_rc / report_rc were set inside show_results
    exit_class=$((exit_class | 2))
  fi
  # results_rc / report_rc distinguish which of the two stages broke; a
  # stage that never ran stays NOT_RUN and is reported as skipped.
  case "${results_rc}" in
    0)       junit_case "[opct] run opct results" ;;
    NOT_RUN) junit_skip "[opct] run opct results" "not executed" ;;
    *)       junit_case "[opct] run opct results" \
               "'${OPCT_CLI} results' exited with code ${results_rc}
$(tail -n 5 "${ARTIFACT_DIR}/log-results.txt" 2>/dev/null)
see log-results.txt" ;;
  esac
  case "${report_rc}" in
    0)       junit_case "[opct] run opct report" ;;
    NOT_RUN) junit_skip "[opct] run opct report" "not executed ('opct results' failed first)" ;;
    *)       junit_case "[opct] run opct report" \
               "'${OPCT_CLI} report' exited with code ${report_rc}
$(tail -n 5 "${ARTIFACT_DIR}/log-report.txt" 2>/dev/null)
see log-report.txt" ;;
  esac
else
  show_msg "WARNING: Skipping results generation -- no result archive available."
  results_rc="NOT_RUN"
  report_rc="NOT_RUN"
  junit_skip "[opct] run opct results" "no result archive available"
  junit_skip "[opct] run opct report" "no result archive available"
fi

# Diagnostic-only: extract container logs from the archive (best-effort).
extract_container_logs || true

# Required: check OPCT's own execution-validity checks.
# Capture the return value directly to preserve the 0/1/2 contract.
if [[ -n "${RESULT_FILE:-}" ]]; then
  local_gate_rc=0
  check_runtime_gate || local_gate_rc=$?
  runtime_gate_rc=${local_gate_rc}
  case ${local_gate_rc} in
    0) ;;  # no gated check failed
    1) exit_class=$((exit_class | 1))  # runtime failure
       show_msg "ERROR: OPCT reported one or more plugins with invalid execution." ;;
    *) exit_class=$((exit_class | 2))  # processing/parse error
       show_msg "ERROR: Runtime gate encountered a processing error." ;;
  esac
else
  runtime_gate_rc="NOT_RUN"
  runtime_gate_reason="no archive available"
  junit_skip "[opct] OPCT execution-validity checks" "no result archive available"
fi

# Exit now if any required operation failed.  Inspect and container logs
# have already been collected; namespace dump runs at exit via the EXIT trap.
if [[ ${exit_class} -ne 0 ]]; then
  emit_summary
  show_msg "FATAL: Required operations failed (exit_class=${exit_class}). See errors above."
  exit ${exit_class}
fi

# Check if job is running in OPCT workflow in allowed job ref to skip upload results to
# OPCT storage.
show_reader "Consolidating artifacts as Baseline Results"
INVALID_OPCT_REPO="true"
VALID_REPOS=("redhat-openshift-ecosystem-opct")
VALID_REPOS+=("periodic-ci-openshift-release-main")
show_msg "Checking if JOB name is allowed to upload results: ${JOB_NAME}"
for VR in "${VALID_REPOS[@]}"; do
  if [[ $JOB_NAME == *"$VR"* ]]; then
    INVALID_OPCT_REPO=false
  fi
done

# Ignore persisting data from unexpected jobs
if [[ "${INVALID_OPCT_REPO}" == "true" ]]; then
  show_msg "# WARNING: Job $JOB_NAME is not allowed to persist baseline results, ignoring it."
  junit_skip "[opct] publish baseline" "job not allowed to persist baseline results"
  junit_skip "[opct] reindex baseline" "job not allowed to persist baseline results"
  emit_summary
  exit 0
fi

#
# Gather some cluster information and upload certification results
#

# shellcheck disable=SC2153 # OPCT_VERSION is defined on ${SHARED_DIR}/env
show_msg "\t> Saving results when passing in pipeline.\n"

# Rename result file to format to be uploaded
artifact_result="${ARTIFACT_DIR}/$(basename "${OBJECT_PATH}")"
mv -v "${RESULT_FILE}" "${artifact_result}"

# Promote the latest summary
# Latest is promoted only if there are valid results:
# - Suite have executions, and not running in dev mode
# - PriorityList for 20* must not be empty
# - Report should not be created with baseline

# Publish results to backend. This command must reject invalid results and return failure.
# CI must catch the failure (exit code) and fail the job.
show_msg "\n\t> Publish results in baseline artifacts storage. meta=[${OBJECT_PATH}]\n"
export OPCT_ENABLE_ADM_BASELINE="1"
local_publish_rc=0
${OPCT_CLI} adm baseline publish --log-level=debug "${artifact_result}" > "${ARTIFACT_DIR}"/log-publish.txt 2>&1 || local_publish_rc=$?
publish_rc=${local_publish_rc}
show_msg "> Debug log saved at {ARTIFACT_DIR}/log-publish.txt\n"

# A rejected baseline (OPCT's own SLO checks, e.g. OPCT-001 Kubernetes
# Conformance pass-rate) and a genuine infra/processing error (e.g. S3
# upload failure) both exit nonzero from 'adm baseline publish' -- grep
# the literal rejection message (pkg/cmd/adm/baseline/publish.go) to tell
# them apart. Per OPCT maintainer direction (Slack 2026-10-26, OPCT-500):
# a rejected baseline is OPCT correctly declining a bad conformance
# result, not a CI/processing failure, and must not fail the job;
# a processing error must.
#
# These markers are logged via logrus.Errorf (non-fatal) in publish.go, so
# the command can still exit 0 even after one fires (e.g. report rendering
# fails but the archive/summary JSON the uploader needs were already
# written). Check for them unconditionally, not just when publish_rc != 0,
# or a real processing error with a successful upload goes undetected.
if grep -qE 'error (processing results|populating report|saving consolidated summary results|saving report results):' "${ARTIFACT_DIR}/log-publish.txt" 2>/dev/null; then
  publish_reason="processing_error"
  show_msg "ERROR: '${OPCT_CLI} adm baseline publish' logged a processing error (exit code ${local_publish_rc}): see log-publish.txt"
  exit_class=$((exit_class | 2))
  # Indexer depends on a trustworthy publish -- mark NOT_RUN.
  indexer_rc="NOT_RUN"
  junit_case "[opct] publish baseline" \
    "'${OPCT_CLI} adm baseline publish' logged a processing error (exit code ${local_publish_rc})
$(tail -n 5 "${ARTIFACT_DIR}/log-publish.txt" 2>/dev/null)
see log-publish.txt"
  junit_skip "[opct] reindex baseline" "not executed (publish failed)"
  emit_summary
  exit ${exit_class}
elif [[ ${local_publish_rc} -ne 0 ]]; then
  if grep -qF 'baseline rejected, see the logs for more details.' "${ARTIFACT_DIR}/log-publish.txt" 2>/dev/null; then
    publish_reason="rejected"
    show_msg "WARNING: '${OPCT_CLI} adm baseline publish' rejected the baseline (not an infra/processing failure, not failing the job): see log-publish.txt"
    # A rejected baseline is OPCT correctly declining a bad conformance
    # result, so the testcase passes -- the rejection is recorded as a skip
    # of the publish rather than a failure of this step.
    junit_skip "[opct] publish baseline" "baseline rejected by OPCT SLO checks (not an infra failure)"
  else
    publish_reason="processing_error"
    show_msg "ERROR: '${OPCT_CLI} adm baseline publish' failed with exit code ${local_publish_rc}"
    exit_class=$((exit_class | 2))
    junit_case "[opct] publish baseline" \
      "'${OPCT_CLI} adm baseline publish' failed with exit code ${local_publish_rc}
$(tail -n 5 "${ARTIFACT_DIR}/log-publish.txt" 2>/dev/null)
see log-publish.txt"
  fi
  # Indexer depends on successful publish -- mark NOT_RUN either way.
  indexer_rc="NOT_RUN"
  junit_skip "[opct] reindex baseline" "not executed (publish did not succeed)"
  emit_summary
  exit ${exit_class}
fi
junit_case "[opct] publish baseline"

# re-index the result to expose the valid baseline.
show_msg "\n\t> Re-indexing the baseline artifacts to be consumed by 'report' and 'opct adm baseline list'\n"
local_indexer_rc=0
${OPCT_CLI} adm baseline indexer --log-level=debug > "${ARTIFACT_DIR}"/log-publish-indexer.txt 2>&1 || local_indexer_rc=$?
indexer_rc=${local_indexer_rc}
show_msg "> Debug log saved at {ARTIFACT_DIR}/log-publish-indexer.txt\n"

if [[ ${local_indexer_rc} -ne 0 ]]; then
  show_msg "ERROR: '${OPCT_CLI} adm baseline indexer' failed with exit code ${local_indexer_rc}"
  exit_class=$((exit_class | 2))
  junit_case "[opct] reindex baseline" \
    "'${OPCT_CLI} adm baseline indexer' failed with exit code ${local_indexer_rc}
$(tail -n 5 "${ARTIFACT_DIR}/log-publish-indexer.txt" 2>/dev/null)
see log-publish-indexer.txt"
  emit_summary
  exit ${exit_class}
fi
junit_case "[opct] reindex baseline"

emit_summary
