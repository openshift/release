#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting e2e test execution in pod ${MAISTRA_SC_POD}..."

# Execute the e2e tests inside the test pod
TEST_RC=0
# Run tests but do not abort here on non-zero to ensure artifact collection
set +e
oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
  sh -c "
  export KUBECONFIG=/work/ci-kubeconfig && \
  oc version && \
  export DOCKER_INSECURE_REGISTRIES=\"default-route-openshift-image-registry.\$(oc get routes -A -o jsonpath='{.items[0].spec.host}' | awk -F. '{print substr(\$0, index(\$0,\$2))}')\" && \
  export BUILD_WITH_CONTAINER=\"0\" && \
  ${VERSIONS_YAML_CONFIG:-} \
  cd /work && \
  entrypoint \
  ${E2E_COMMAND:-make test.e2e.ocp}"
TEST_RC=$?
set -e

echo "Copying artifacts from test pod..."
# Copy artifacts from the test pod
oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"

# Print out the copied artifact structure for debugging
echo "Artifact directory contents under ${ARTIFACT_DIR}:"
ls -laR "${ARTIFACT_DIR}"

# Validate that a JUnit report was produced (search recursively in case oc cp nested paths)
if ! find "${ARTIFACT_DIR}" -type f \( -name 'junit*.xml' -o -name 'report.xml' \) -print -quit | grep -q .; then
  echo "ERROR: No JUnit report found in ${ARTIFACT_DIR}. Marking job as failed." >&2
  if [ "${TEST_RC}" -eq 0 ]; then
    TEST_RC=1
  fi
fi

# Exit with the test status after artifact collection/validation
if [ "${TEST_RC}" -ne 0 ]; then
  echo "E2E tests failed with exit code ${TEST_RC}" >&2
  exit "${TEST_RC}"
fi

echo "E2E test execution completed"
