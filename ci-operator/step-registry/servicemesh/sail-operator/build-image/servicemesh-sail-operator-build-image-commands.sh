#!/bin/bash

# ==============================================================================
# Sail Operator Image Build Script
#
# Builds the sail-operator container image using an OCP BuildConfig and pushes
# it to an external quay.io registry. The built image coordinates (HUB and TAG)
# are written to SHARED_DIR for consumption by downstream test steps.
#
# The image tag is suffixed with the target architecture (e.g. "-amd64", "-arm64")
# so that parallel amd64 and arm64 CI jobs push to distinct tags and do not
# overwrite each other.
#
# Steps:
# 1. Detects the current architecture via `go env GOARCH`.
# 2. Derives a unique, arch-suffixed image tag from Prow build metadata.
# 3. Creates an OCP Secret with the quay.io push credentials.
# 4. Pre-compiles the operator binary with `make build` (which auto-selects
#    the binary output path via setup_env.sh: out/linux_${ARCH}/sail-operator).
# 5. Creates (or updates) an OCP BuildConfig with Docker strategy.
#    Patches the BuildConfig with TARGETARCH so the Dockerfile picks up the
#    correct pre-compiled binary from the uploaded source tree.
# 6. Starts the build with the full source tree as context and waits.
# 7. Writes HUB and TAG to SHARED_DIR for downstream steps.
#
# Dockerfile expectation (sail-operator repo):
#   ADD out/${TARGETOS:-linux}_${TARGETARCH:-amd64}/sail-operator /sail-operator
#   TARGETARCH must be passed as a Docker build arg; without it the Dockerfile
#   defaults to amd64 and the ADD fails on arm64 nodes.
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

readonly BUILD_NAME="sail-operator-ci-build"

# --- Architecture detection ---
# go env GOARCH reflects the native arch of the CI node (amd64 on standard nodes,
# arm64 on r6g.xlarge nodes). This matches what setup_env.sh derives from uname -m,
# so 'make build' compiles to out/linux_${ARCH}/sail-operator.
ARCH=$(go env GOARCH)
echo "Target architecture: ${ARCH}"

# --- Tag derivation ---
# Suffix the tag with the arch so amd64 and arm64 jobs push to separate images.
# BUILD_ID is always set by Prow and is unique per job run.
if [[ -n "${PULL_NUMBER:-}" ]]; then
  COMPUTED_TAG="pr-${PULL_NUMBER}-${BUILD_ID}-${ARCH}"
else
  COMPUTED_TAG="${BUILD_ID}-${ARCH}"
fi
readonly COMPUTED_TAG
echo "Image tag: ${COMPUTED_TAG}"
echo "Target image: ${HUB}/sail-operator:${COMPUTED_TAG}"

# --- Credentials ---
if [[ ! -f /tmp/secrets/username ]] || [[ ! -f /tmp/secrets/password ]]; then
  echo "ERROR: quay.io credentials not found at /tmp/secrets/username and /tmp/secrets/password" >&2
  exit 1
fi

# Disable tracing while handling credentials
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_USERNAME=$(cat /tmp/secrets/username)
QUAY_PASSWORD=$(cat /tmp/secrets/password)

# Create or update the push secret in the current namespace
oc create secret docker-registry sail-quay-push \
  --docker-server=quay.io \
  --docker-username="${QUAY_USERNAME}" \
  --docker-password="${QUAY_PASSWORD}" \
  --docker-email=unused@ci.invalid \
  --dry-run=client -o yaml | oc apply -f -
$WAS_TRACING && set -x

# --- Pre-compile the operator binary ---
# setup_env.sh (sourced by make via Makefile) auto-detects TARGET_ARCH from uname -m
# and compiles the binary to out/linux_${ARCH}/sail-operator.
# BUILD_WITH_CONTAINER=0 ensures the build runs in-process without spawning a container.
echo "Pre-compiling operator binary for ${ARCH}..."
BUILD_WITH_CONTAINER=0 XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/cache}" make build

# Verify the binary exists at the path the Dockerfile expects
readonly BINARY_PATH="out/linux_${ARCH}/sail-operator"
if [[ ! -f "${BINARY_PATH}" ]]; then
  echo "ERROR: Expected binary not found at ${BINARY_PATH} after 'make build'." >&2
  echo "       Contents of out/:" >&2
  find out/ -type f 2>/dev/null || echo "(out/ directory is empty or missing)" >&2
  exit 1
fi
echo "Binary built: ${BINARY_PATH}"

# --- OCP BuildConfig ---
# Binary Docker strategy: uploads the local source tree (including the pre-compiled
# binary) and builds the container image on an OCP build pod, then pushes to quay.io.
#
# Idempotent: if the BC already exists (e.g. a job retry in the same namespace),
# patch its output target to the current COMPUTED_TAG so we don't push to a stale tag.
if oc get "bc/${BUILD_NAME}" &>/dev/null; then
  echo "BuildConfig ${BUILD_NAME} already exists; updating output target for this run."
  oc patch "bc/${BUILD_NAME}" --type=merge -p \
    "{\"spec\":{\"output\":{\"to\":{\"name\":\"${HUB}/sail-operator:${COMPUTED_TAG}\"}}}}"
else
  echo "Creating BuildConfig: ${BUILD_NAME}"
  oc new-build \
    --binary \
    --strategy=docker \
    --name="${BUILD_NAME}" \
    --to="${HUB}/sail-operator:${COMPUTED_TAG}" \
    --push-secret=sail-quay-push \
    --to-docker=true
fi

# Ensure the push secret is linked regardless of whether we just created the BC
oc set build-secret --push "bc/${BUILD_NAME}" sail-quay-push

# Pass TARGETARCH as a Docker build arg so the Dockerfile selects the correct
# pre-compiled binary: ADD out/linux_${TARGETARCH}/sail-operator /sail-operator.
# Without this, the Dockerfile defaults to amd64 and the ADD fails on arm64 nodes.
oc patch "bc/${BUILD_NAME}" --type=merge -p \
  "{\"spec\":{\"strategy\":{\"dockerStrategy\":{\"buildArgs\":[{\"name\":\"TARGETARCH\",\"value\":\"${ARCH}\"}]}}}}"

# Capture the next build number before starting so the post-start status check
# can anchor to the specific Build object rather than using a label selector.
NEXT_BUILD_NUM=$(( $(oc get "bc/${BUILD_NAME}" -o jsonpath='{.status.lastVersion}' 2>/dev/null || echo 0) + 1 ))
readonly NEXT_BUILD_NUM

echo "Starting build from local source tree (will be ${BUILD_NAME}-${NEXT_BUILD_NUM})..."
oc start-build "${BUILD_NAME}" --from-dir=. --follow

# --- Verify completion ---
# oc start-build --follow exits non-zero on build failure, but the explicit check
# guards against edge cases (e.g. connection drops masking a Failed status).
# Anchored to NEXT_BUILD_NUM to avoid picking up a previous successful build.
readonly STARTED_BUILD="${BUILD_NAME}-${NEXT_BUILD_NUM}"
BUILD_STATUS=$(oc get "build/${STARTED_BUILD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "${BUILD_STATUS}" != "Complete" ]]; then
  echo "ERROR: Build ${STARTED_BUILD} ended with status '${BUILD_STATUS}' (expected 'Complete')." >&2
  oc get "build/${STARTED_BUILD}" -o wide 2>/dev/null || true
  exit 1
fi

echo "Build completed successfully."

# --- Write image coordinates to SHARED_DIR for downstream steps ---
set +x
echo "${HUB}" > "${SHARED_DIR}/BUILD_HUB"
echo "${COMPUTED_TAG}" > "${SHARED_DIR}/BUILD_TAG"
$WAS_TRACING && set -x

echo "Image coordinates written to SHARED_DIR:"
echo "  BUILD_HUB = ${HUB}"
echo "  BUILD_TAG = ${COMPUTED_TAG}"
