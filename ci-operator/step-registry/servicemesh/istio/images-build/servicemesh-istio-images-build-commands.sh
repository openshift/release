#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# Derive a unique image tag from Prow-injected variables:
#   - PRs:        PULL_PULL_SHA  (consistent across re-triggers on the same commit)
#   - Postsubmit: BUILD_ID       (unique per run)
if [ -n "${PULL_PULL_SHA:-}" ]; then
  export TAG="${PULL_PULL_SHA}"
elif [ -n "${BUILD_ID:-}" ]; then
  export TAG="${BUILD_ID}"
else
  echo "ERROR: Neither PULL_PULL_SHA nor BUILD_ID is set. Cannot derive a unique image tag." >&2
  exit 1
fi
echo "Building images with TAG: ${TAG}"

QUAY_USERNAME=$(cat /tmp/secrets/username)
QUAY_PASSWORD=$(cat /tmp/secrets/password)

echo "Copying source code to ${MAISTRA_SC_POD}..."
oc cp ./. "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":/work/
echo "Copying kubeconfig to ${MAISTRA_SC_POD}..."
oc cp "${KUBECONFIG}" "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":/work/ci-kubeconfig

oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
  sh -c "
  docker login -u=\"${QUAY_USERNAME}\" -p=\"${QUAY_PASSWORD}\" quay.io
  export KUBECONFIG=/work/ci-kubeconfig
  export BUILD_WITH_CONTAINER=\"0\"
  export ENABLE_OVERLAY2_STORAGE_DRIVER=true
  export HUB=\"${QUAY_HUB}\"
  export TAG=\"${TAG}\"
  export SKIP_TEST_RUN=\"true\"
  export ARTIFACT_DIR=\"${ARTIFACT_DIR}\"
  export INSTALL_SAIL_OPERATOR=\"${INSTALL_SAIL_OPERATOR:-false}\"
  oc version
  cd /work
  entrypoint prow/integ-suite-ocp.sh
  "
