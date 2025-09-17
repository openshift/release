#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting scorecard test execution in pod ${MAISTRA_SC_POD}..."

# Execute the scorecard tests inside the test pod
oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
  entrypoint \
  sh -c \
  "export KUBECONFIG=/work/ci-kubeconfig && \
  cd /work && \
  export BUILD_WITH_CONTAINER=\"0\" && \
  ${SCORECARD_COMMAND:-make test.scorecard}"

echo "Copying artifacts from test pod..."
# Copy artifacts from the test pod
oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"

echo "Scorecard test execution completed"