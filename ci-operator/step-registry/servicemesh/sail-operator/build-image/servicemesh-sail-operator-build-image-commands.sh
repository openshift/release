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
# All OCP resources (Secret, BuildConfig, Build) are created in this namespace
# on the test cluster. Must be explicit: the step container runs on the build
# cluster (api.ci) in a ci-op-* namespace, and oc --dry-run=client will embed
# that namespace in generated YAML unless we override it here.
readonly OCP_NAMESPACE="default"

# --- Architecture detection ---
# go env GOARCH reflects the native arch of the CI node (amd64 on standard nodes,
# arm64 on r6g.xlarge nodes). This matches what setup_env.sh derives from uname -m,
# so 'make build' compiles to out/linux_${ARCH}/sail-operator.
ARCH=$(go env GOARCH)
echo "Target architecture: ${ARCH}"

# --- Tag derivation ---
# Suffix the tag with the arch so amd64 and arm64 jobs push to separate images.
#
# For presubmit (PR) jobs, use the first 8 chars of PULL_PULL_SHA to match the
# tag that common-operator-integ-suite.sh computes internally. If we use BUILD_ID
# instead, the test suite deploys a different tag than the one we pushed and the
# operator pod fails to pull the image.
# For periodic/postsubmit jobs (no PULL_NUMBER), fall back to BUILD_ID which is
# always unique per run.
if [[ -n "${PULL_NUMBER:-}" ]]; then
  if [[ -z "${PULL_PULL_SHA:-}" ]]; then
    echo "ERROR: PULL_PULL_SHA is not set for a presubmit job. Cannot compute PR image tag." >&2
    exit 1
  fi
  COMMIT_HASH="${PULL_PULL_SHA:0:8}"
  COMPUTED_TAG="pr-${PULL_NUMBER}-${COMMIT_HASH}-${ARCH}"
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

# Create or update the push secret in OCP_NAMESPACE on the test cluster.
# --namespace is explicit on both sides of the pipe so the generated YAML
# carries the correct namespace (not the build cluster's ci-op-* namespace).
oc create secret docker-registry sail-quay-push \
  --namespace="${OCP_NAMESPACE}" \
  --docker-server=quay.io \
  --docker-username="${QUAY_USERNAME}" \
  --docker-password="${QUAY_PASSWORD}" \
  --docker-email=unused@ci.invalid \
  --dry-run=client -o yaml | oc apply -n "${OCP_NAMESPACE}" -f -
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
if oc get -n "${OCP_NAMESPACE}" "bc/${BUILD_NAME}" &>/dev/null; then
  echo "BuildConfig ${BUILD_NAME} already exists; updating output target for this run."
  oc patch -n "${OCP_NAMESPACE}" "bc/${BUILD_NAME}" --type=merge -p \
    "{\"spec\":{\"output\":{\"to\":{\"name\":\"${HUB}/sail-operator:${COMPUTED_TAG}\"}}}}"
else
  echo "Creating BuildConfig: ${BUILD_NAME}"
  oc new-build \
    --namespace="${OCP_NAMESPACE}" \
    --binary \
    --strategy=docker \
    --name="${BUILD_NAME}" \
    --to="${HUB}/sail-operator:${COMPUTED_TAG}" \
    --push-secret=sail-quay-push \
    --to-docker=true
fi

# Ensure the push secret is linked regardless of whether we just created the BC
oc set build-secret --push -n "${OCP_NAMESPACE}" "bc/${BUILD_NAME}" sail-quay-push

# Pass TARGETARCH as a Docker build arg so the Dockerfile selects the correct
# pre-compiled binary: ADD out/linux_${TARGETARCH}/sail-operator /sail-operator.
# Without this, the Dockerfile defaults to amd64 and the ADD fails on arm64 nodes.
oc patch -n "${OCP_NAMESPACE}" "bc/${BUILD_NAME}" --type=merge -p \
  "{\"spec\":{\"strategy\":{\"dockerStrategy\":{\"buildArgs\":[{\"name\":\"TARGETARCH\",\"value\":\"${ARCH}\"}]}}}}"

# Start the build and capture the exact Build reference (e.g. "build/sail-operator-ci-build-1").
# Using --output=name avoids predicting the build number, so retries and any
# concurrent builds on the same BC are handled correctly.
echo "Starting build from local source tree..."
STARTED_BUILD=$(oc start-build -n "${OCP_NAMESPACE}" "${BUILD_NAME}" --from-dir=. --output=name)
readonly STARTED_BUILD
echo "Build started: ${STARTED_BUILD}"

# Stream build pod logs; returns when the build pod terminates.
# Note: the Build API object may still show 'Running' briefly after the pod
# exits while OpenShift updates the status — poll below to handle that lag.
oc logs -n "${OCP_NAMESPACE}" -f "${STARTED_BUILD}" || true

# --- Wait for terminal status, then verify ---
# Poll up to 5 minutes (should settle within seconds in practice).
BUILD_STATUS="Unknown"
for _ in $(seq 1 60); do
  BUILD_STATUS=$(oc get -n "${OCP_NAMESPACE}" "${STARTED_BUILD}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  case "${BUILD_STATUS}" in
    Complete|Failed|Error|Cancelled) break ;;
  esac
  echo "Build status: ${BUILD_STATUS} — waiting for terminal state..."
  sleep 5
done

if [[ "${BUILD_STATUS}" != "Complete" ]]; then
  echo "ERROR: ${STARTED_BUILD} ended with status '${BUILD_STATUS}' (expected 'Complete')." >&2
  oc get -n "${OCP_NAMESPACE}" "${STARTED_BUILD}" -o wide 2>/dev/null || true
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
