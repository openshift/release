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

# Retrieve after successful execution
show_msg "Retrieving Results..."
mkdir -p "${ARTIFACT_DIR}/opct-results"
${OPCT_CLI} retrieve "${ARTIFACT_DIR}/opct-results"

# Ignored failures when saving artifacts
set -x
set +o pipefail
set +o errexit

RESULT_FILE=$(ls "${ARTIFACT_DIR}"/opct-results/*.tar*)

function show_results() {
  # Run results summary (to log to file)
  show_msg "running: ${OPCT_CLI} results"
  ${OPCT_CLI} results "${RESULT_FILE}"

  # Run report (to log to file)
  show_msg "running: ${OPCT_CLI} report"
  ${OPCT_CLI} report --server-skip --loglevel=debug --save-to "${ARTIFACT_DIR}"/opct-report "${RESULT_FILE}" || true
}
show_results || true

# Check if job is running in OPCT repo to skip upload results to
# OPCT storage.
INVALID_OPCT_REPO="true"
VALID_REPOS=("redhat-openshift-ecosystem-provider-certification-tool")
VALID_REPOS+=("redhat-openshift-ecosystem-opct")
for VR in "${VALID_REPOS[@]}"; do
  if [[ $JOB_NAME == *"$VR"* ]]; then
    INVALID_OPCT_REPO=false
  fi
done

# Ignore persisting data in non OPCT/repo jobs
if [[ "${INVALID_OPCT_REPO}" == "true" ]]; then
  echo -e "\n# INFO: Job $JOB_NAME is not allowed to persist baseline results, ignoring it."
  exit 0
fi

#
# Gather some cluster information and upload certification results
#

# shellcheck disable=SC2153 # OPCT_VERSION is defined on ${SHARED_DIR}/install-env
show_msg "Saving file on bucket [opct] and path [${OBJECT_PATH}]"
echo "Meta: ${OBJECT_META}"
echo "URL: https://openshift-provider-certification.s3.us-west-2.amazonaws.com/index.html"

# Rename result file to format to be uploaded
artifact_result="${ARTIFACT_DIR}/$(basename "${OBJECT_PATH}")"
mv -v "${RESULT_FILE}" "${artifact_result}"

export OPCT_ENABLE_EXP_PUBLISH="1"
${OPCT_CLI} exp publish "${artifact_result}" \
  --key "${OBJECT_PATH}" \
  --metadata "${OBJECT_META}"
