#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting e2e test execution in pod ${MAISTRA_SC_POD}..."

# Execute the e2e tests inside the test pod
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

echo "Copying artifacts from test pod..."
# Copy artifacts from the test pod
oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"

echo "E2E test execution completed"
