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
echo "${TAG}" > "${SHARED_DIR}/istio-image-tag"

# Copy credential files into the pod as files so their values never appear in
# any process command-line argument (oc rsh, sh -c, or docker login).
oc cp /tmp/secrets/username "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}":/tmp/quay-username
oc cp /tmp/secrets/password "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}":/tmp/quay-password

oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
  sh -c "
  docker login -u=\"\$(cat /tmp/quay-username)\" --password-stdin quay.io < /tmp/quay-password
  rm -f /tmp/quay-username /tmp/quay-password
  export KUBECONFIG=/work/ci-kubeconfig
  export BUILD_WITH_CONTAINER=\"0\"
  export ENABLE_OVERLAY2_STORAGE_DRIVER=true
  export HUB=\"${TEST_HUB}\"
  export TAG=\"${TAG}\"
  export SKIP_TEST_RUN=\"true\"
  export ARTIFACT_DIR=\"${ARTIFACT_DIR}\"
  export INSTALL_SAIL_OPERATOR=\"${INSTALL_SAIL_OPERATOR:-false}\"
  export GOFLAGS=-buildvcs=false
  oc version
  cd /work
  entrypoint prow/integ-suite-ocp.sh
  "
