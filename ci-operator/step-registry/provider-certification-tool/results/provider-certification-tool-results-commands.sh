#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

# Retrieve after successful execution
show_msg "Retrieving Results..."
mkdir -p "${ARTIFACT_DIR}/certification-results"
${OPCT_EXEC} retrieve "${ARTIFACT_DIR}/certification-results"

# Run results summary (to log to file)
show_msg "running: ${OPCT_EXEC} results"
${OPCT_EXEC} results "${ARTIFACT_DIR}"/certification-results/*.tar.gz

# Run report (to log to file)
show_msg "running: ${OPCT_EXEC} report --verbose"
${OPCT_EXEC} report --verbose "${ARTIFACT_DIR}"/certification-results/*.tar.gz

#
# Gather some cluster information and upload certification results
#
install_awscli

# shellcheck disable=SC2153 # OPCT_VERSION is defined on ${SHARED_DIR}/install-env
show_msg "Saving file on bucket [openshift-provider-certification] and path [${OBJECT_PATH}]"
echo "Meta: ${OBJECT_META}"
echo "URL: https://openshift-provider-certification.s3.us-west-2.amazonaws.com/index.html"

aws s3 cp --only-show-errors --metadata "${OBJECT_META}" \
  "${ARTIFACT_DIR}"/certification-results/*.tar.gz \
  "s3://openshift-provider-certification/${OBJECT_PATH}"