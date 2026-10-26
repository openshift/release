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

# --- Return-code accounting ------------------------------------------------
# Each processing stage gets a dedicated variable initialised to NOT_RUN so
# that an unexecuted stage is never confused with exit-code 0.  Raw codes
# from each command are preserved exactly as returned and reported in the
# structured summary.
retrieve_rc="NOT_RUN"
retrieve_tee_rc="NOT_RUN"
retrieve_pipe_rc="NOT_RUN"
results_rc="NOT_RUN"
report_rc="NOT_RUN"
publish_rc="NOT_RUN"
indexer_rc="NOT_RUN"

# check_plugin_gate return contract:
#   0 = all intended plugins passed
#   1 = valid intent, at least one required plugin missing or non-passed
#   2 = untrustworthy intent or parse error (processing problem)
plugin_gate_rc="NOT_RUN"
plugin_gate_reason=""

# Exit classes:
#   0 = success (all stages passed)
#   1 = plugin_failure (intended plugin(s) did not pass)
#   2 = processing_failure (infrastructure/processing error)
#   3 = both (plugin failure AND processing failure)
exit_class=0

# Set by _signal_handler when a signal is caught.
_caught_signal=""

# emit_summary writes the structured summary block to both console and
# ARTIFACT_DIR (durable).  It is called in the normal flow and from the
# EXIT trap so it always appears.  Values that may contain whitespace or
# special characters are quoted to keep the block unambiguous.
summary_emitted=""
function emit_summary() {
  [[ -n "${summary_emitted}" ]] && return
  summary_emitted=1

  # Quote plugin_gate_reason: replace newlines and single-quotes so the
  # block stays parseable as a simple key=value list.
  local safe_reason="${plugin_gate_reason//$'\n'/ }"
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
  elif [[ ${exit_class} -ne 0 && -z "${plugin_gate_reason}" && "${plugin_gate_rc}" == "0" ]]; then
    raw_status="late-failure"
    raw_reason="exit_class set to ${exit_class} after passing gate"
  fi

  local block
  block=$(cat <<EOS

#>> OPCT_RESULTS_SUMMARY
retrieve_rc=${retrieve_rc}
retrieve_tee_rc=${retrieve_tee_rc}
retrieve_pipe_rc=${retrieve_pipe_rc}
results_rc=${results_rc}
report_rc=${report_rc}
publish_rc=${publish_rc}
indexer_rc=${indexer_rc}
plugin_gate_rc=${plugin_gate_rc}
plugin_gate_reason='${safe_reason}'
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
  ${OPCT_CLI} retrieve "${ARTIFACT_DIR}/opct-results" | tee -a "${ARTIFACT_DIR}"/log-retrieve.txt
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
    show_msg "ERROR: '${OPCT_CLI} retrieve' failed with exit code ${retrieve_rc} (tee=${retrieve_tee_rc})"
    return 1
  fi

  # tee failure is a processing error (log may be incomplete) even if
  # retrieve itself succeeded.
  if [[ ${retrieve_tee_rc} -ne 0 ]]; then
    show_msg "ERROR: tee pipeline failed with exit code ${retrieve_tee_rc} (retrieve=${retrieve_rc})"
    return 1
  fi

  # Identify the single result archive.  Glob into an array to detect
  # missing or ambiguous results without relying on ls output parsing.
  local -a archives=("${ARTIFACT_DIR}"/opct-results/*.tar*)
  if [[ ${#archives[@]} -eq 0 || ! -f "${archives[0]}" ]]; then
    show_msg "ERROR: no result archive found in ${ARTIFACT_DIR}/opct-results/"
    return 1
  fi
  if [[ ${#archives[@]} -gt 1 ]]; then
    show_msg "ERROR: multiple result archives found in ${ARTIFACT_DIR}/opct-results/ (${#archives[@]} files)"
    return 1
  fi
  RESULT_FILE="${archives[0]}"
}

function show_results() {
  show_reader "Exporting Results"

  # Run results summary (to log to file).
  # Explicit return-code checks are required because this function is called
  # inside 'if !', which disables errexit for the entire function body.
  show_msg "\t>> running: ${OPCT_CLI} results\n"
  local rc=0
  ${OPCT_CLI} results "${RESULT_FILE}" > "${ARTIFACT_DIR}"/log-results.txt || rc=$?
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
    "${RESULT_FILE}" > "${ARTIFACT_DIR}"/log-report.txt || rc=$?
  report_rc=${rc}
  if [[ ${rc} -ne 0 ]]; then
    show_msg "ERROR: '${OPCT_CLI} report' exited with code ${rc}"
    return ${rc}
  fi
}

# check_plugin_gate validates that every plugin OPCT actually executed
# reports stat.status == "passed", reading the structured opct-report.json
# produced by 'opct report --save-to' -- the same data contract the OPCT
# web UI consumes (internal/report/data.go ReportFileNameIndexJSON).
#
# .provider.plugins is populated only for plugins that produced results
# (internal/report/data.go populatePluginConformance skips absent plugins),
# so its key set already reflects run-mode intent -- e.g. upgrade mode
# omitting plugins 10/20/80 -- without a separate parse of the archive's
# meta/info.json. .stat.status mirrors the raw Sonobuoy plugin status
# (same source Sonobuoy's own results text output prints), as opposed to
# .stat.result which OPCT overrides for display (e.g. forced to "---" for
# the Replay plugin when filtered failures exist).
#
# Return values (contract):
#   0 = all executed plugins report stat.status == "passed"
#   1 = valid report parsed, but at least one plugin is non-passed
#       (plugin failure)
#   2 = report missing or malformed (processing problem)
#
# The caller must capture the return value directly; using 'if !' would
# lose the distinction between 1 and 2.
function check_plugin_gate() {
  show_reader "Checking plugin results gate"

  local report_json="${ARTIFACT_DIR}/opct-report/opct-report.json"
  if [[ ! -f "${report_json}" ]]; then
    plugin_gate_reason="opct-report.json missing at ${report_json}"
    show_msg "ERROR: ${plugin_gate_reason}"
    return 2
  fi

  # Parse with jq.  This step uses the 'cli-jq' supplemental image
  # (base cli + jq) because the base 'cli' image does not include jq.
  local plugins_json
  plugins_json=$(jq -e -c '
    .provider.plugins
    | if type != "object" then error("provider.plugins is not an object: \(type)") else . end
    | if length == 0 then error("provider.plugins is empty") else . end
    | to_entries
    | map({name: .key, status: .value.stat.status})
  ' "${report_json}" 2>&1) || {
    plugin_gate_reason="failed to parse ${report_json}: ${plugins_json}"
    show_msg "ERROR: ${plugin_gate_reason}"
    return 2
  }

  local total
  total=$(echo "${plugins_json}" | jq 'length')
  show_msg "Executed plugins (from opct-report.json): $(echo "${plugins_json}" | jq -r '[.[].name] | join(" ")')"

  local failed_json
  failed_json=$(echo "${plugins_json}" | jq -c '[.[] | select(.status != "passed")]')
  local failed_count
  failed_count=$(echo "${failed_json}" | jq 'length')

  if [[ ${failed_count} -ne 0 ]]; then
    plugin_gate_reason=$(echo "${failed_json}" | jq -r '
      [.[] | "plugin \u0027\(.name)\u0027 status: \(.status) (expected passed)"] | join("; ")
    ')
    show_msg "ERROR: Plugin gate FAILED: ${plugin_gate_reason}"
    return 1
  fi

  show_msg "Plugin gate passed: all ${total} executed plugin(s) report stat.status: passed"
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
fi

# Required: generate results summary and report.
# Only attempt if retrieval succeeded (RESULT_FILE is set).
if [[ -n "${RESULT_FILE:-}" ]]; then
  if ! show_results; then
    show_msg "ERROR: Failed to generate results summary or report."
    # results_rc / report_rc were set inside show_results
    exit_class=$((exit_class | 2))
  fi
else
  show_msg "WARNING: Skipping results generation -- no result archive available."
  results_rc="NOT_RUN"
  report_rc="NOT_RUN"
fi

# Diagnostic-only: extract container logs from the archive (best-effort).
extract_container_logs || true

# Required: check plugin results gate.
# Capture the return value directly to preserve the 0/1/2 contract.
if [[ -f "${ARTIFACT_DIR}/opct-report/opct-report.json" ]]; then
  local_gate_rc=0
  check_plugin_gate || local_gate_rc=$?
  plugin_gate_rc=${local_gate_rc}
  case ${local_gate_rc} in
    0) ;;  # all plugins passed
    1) exit_class=$((exit_class | 1))  # plugin failure
       show_msg "ERROR: Required plugin results contain failures." ;;
    *) exit_class=$((exit_class | 2))  # processing/parse error
       show_msg "ERROR: Plugin gate encountered a processing error." ;;
  esac
elif [[ -n "${RESULT_FILE:-}" ]]; then
  show_msg "ERROR: opct-report.json missing after results generation."
  plugin_gate_rc=2
  plugin_gate_reason="opct-report.json not generated"
  exit_class=$((exit_class | 2))
else
  plugin_gate_rc="NOT_RUN"
  plugin_gate_reason="no archive available"
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
VALID_REPOS=("redhat-openshift-ecosystem-provider-certification-tool")
VALID_REPOS+=("redhat-openshift-ecosystem-opct")
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
${OPCT_CLI} adm baseline publish --log-level=debug "${artifact_result}" > "${ARTIFACT_DIR}"/log-publish.txt || local_publish_rc=$?
publish_rc=${local_publish_rc}
show_msg "> Debug log saved at {ARTIFACT_DIR}/log-publish.txt\n"

if [[ ${local_publish_rc} -ne 0 ]]; then
  show_msg "ERROR: '${OPCT_CLI} adm baseline publish' failed with exit code ${local_publish_rc}"
  exit_class=$((exit_class | 2))
  # Indexer depends on successful publish -- mark NOT_RUN.
  indexer_rc="NOT_RUN"
  emit_summary
  exit ${exit_class}
fi

# re-index the result to expose the valid baseline.
show_msg "\n\t> Re-indexing the baseline artifacts to be consumed by 'report' and 'opct adm baseline list'\n"
local_indexer_rc=0
${OPCT_CLI} adm baseline indexer --log-level=debug > "${ARTIFACT_DIR}"/log-publish-indexer.txt || local_indexer_rc=$?
indexer_rc=${local_indexer_rc}
show_msg "> Debug log saved at {ARTIFACT_DIR}/log-publish-indexer.txt\n"

if [[ ${local_indexer_rc} -ne 0 ]]; then
  show_msg "ERROR: '${OPCT_CLI} adm baseline indexer' failed with exit code ${local_indexer_rc}"
  exit_class=$((exit_class | 2))
  emit_summary
  exit ${exit_class}
fi

emit_summary
