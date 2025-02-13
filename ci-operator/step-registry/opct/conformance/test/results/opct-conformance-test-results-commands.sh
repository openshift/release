#!/bin/bash

#
# Extract the results from the test environment (aggregator server).
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
extract_opct

trap 'dump_opct_namespace' EXIT TERM INT

# Retrieve after successful execution
show_msg "Retrieving Results..."
mkdir -p "${ARTIFACT_DIR}/opct-results"
${OPCT_CLI} retrieve "${ARTIFACT_DIR}/opct-results"
RESULT_FILE=$(ls "${ARTIFACT_DIR}"/opct-results/*.tar*)

function show_results() {
  # Run results summary (to log to file)
  show_msg "\t>> running: ${OPCT_CLI} results\n"
  ${OPCT_CLI} results "${RESULT_FILE}" | tee -a "${ARTIFACT_DIR}"/results.txt

  # Run report (to log to file)
  show_msg "\t>> running: ${OPCT_CLI} report\n"
  ${OPCT_CLI} report \
    --skip-server \
    --log-level=debug \
    --save-to "${ARTIFACT_DIR}"/opct-report \
    "${RESULT_FILE}" || true  | tee -a "${ARTIFACT_DIR}"/report.txt
}
show_results || true

# Check if job is running in OPCT repo to skip upload results to
# OPCT storage.
INVALID_OPCT_REPO="true"
VALID_REPOS=("redhat-openshift-ecosystem-provider-certification-tool")
VALID_REPOS+=("redhat-openshift-ecosystem-opct")
show_msg "Checking if JOB name is allowed to upload results: ${JOB_NAME}"
for VR in "${VALID_REPOS[@]}"; do
  if [[ $JOB_NAME == *"$VR"* ]]; then
    INVALID_OPCT_REPO=false
  fi
done

# Ignore persisting data in non OPCT/repo jobs
if [[ "${INVALID_OPCT_REPO}" == "true" ]]; then
  show_msg "# ERROR: Job $JOB_NAME is not allowed to persist baseline results, ignoring it."
  exit 0
fi

#
# Gather some cluster information and upload certification results
#

# shellcheck disable=SC2153 # OPCT_VERSION is defined on ${SHARED_DIR}/env
show_msg "\t> Saving results when passing in pipeline.\n"
echo "Meta: ${OBJECT_META}"

# Rename result file to format to be uploaded
artifact_result="${ARTIFACT_DIR}/$(basename "${OBJECT_PATH}")"
mv -v "${RESULT_FILE}" "${artifact_result}"

# Promote the latest summary
# Latest is promoted only if there are valid results:
# - Suite have executions, and not running in dev mode
# - PriorityList for 20* must not be empty
# - Report should not be created with baseline

# Publish results to backend. This command must reject invalid results and return failure.
# CI must caught the failure (exit code) and fail the job.
show_msg "\t> Publish results in baseline artifacts storage. meta=[${OBJECT_PATH}]\n"
export OPCT_ENABLE_ADM_BASELINE="1"
${OPCT_CLI} adm baseline publish --log-level=debug "${artifact_result}" || true

# re-index the result to expose the valid baseline.
show_msg "\t> Re-indexing the baseline artifacts to be consumed by 'report' and 'opct adm baseline list'\n"
${OPCT_CLI} adm baseline indexer --log-level=debug || true
