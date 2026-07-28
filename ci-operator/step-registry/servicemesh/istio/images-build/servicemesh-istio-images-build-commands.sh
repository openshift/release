#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

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

# Kubernetes mounts secrets as symlinks; oc cp copies the symlink itself, not the
# content, so the target path doesn't exist in the pod. Read content in the step
# container and pipe directly to docker login via stdin to avoid the issue entirely.
[[ $- == *x* ]] && _WAS_TRACING=true || _WAS_TRACING=false
set +x
QUAY_USERNAME=$(cat /tmp/secrets/username)
QUAY_PASSWORD=$(cat /tmp/secrets/password)
printf '%s' "${QUAY_PASSWORD}" | \
  oc exec -i -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -- \
  docker login -u "${QUAY_USERNAME}" --password-stdin quay.io
$_WAS_TRACING && set -x

oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
  sh -c "
  export KUBECONFIG=/work/ci-kubeconfig
  export BUILD_WITH_CONTAINER=\"0\"
  export ENABLE_OVERLAY2_STORAGE_DRIVER=true
  export HUB=\"${QUAY_HUB}\"
  export TAG=\"${TAG}\"
  export SKIP_TEST_RUN=\"true\"
  export ARTIFACT_DIR=\"${ARTIFACT_DIR}\"
  export INSTALL_SAIL_OPERATOR=\"${INSTALL_SAIL_OPERATOR:-false}\"
  export GOFLAGS=-buildvcs=false
  oc version
  cd /work
  entrypoint prow/integ-suite-ocp.sh
  "
