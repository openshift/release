#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=========================================="
echo "Sandboxed Containers Operator - Optional Must-Gather"
echo "=========================================="

# Check if must-gather is enabled
if [[ "${ENABLE_MUST_GATHER:-true}" != "true" ]]; then
    echo "Must-gather collection is disabled (ENABLE_MUST_GATHER=${ENABLE_MUST_GATHER:-})"
    echo "Skipping must-gather step"
    exit 0
fi

# Check if we should only run on failure
if [[ "${MUST_GATHER_ON_FAILURE_ONLY:-false}" == "true" ]]; then
    echo "Must-gather configured to run only on test failures"

    # Check for test failure indicators
    # Method 1: Check for JUnit test results with failures
    if find "${ARTIFACT_DIR}" -name "junit_*.xml" -type f 2>/dev/null | head -1 | xargs grep -q 'failures="[1-9]' 2>/dev/null; then
        echo "Found JUnit test failures"
    # Method 2: Check for specific failure marker files that might be created by test steps
    elif [[ -f "${SHARED_DIR}/test-failures" ]] || [[ -f "${ARTIFACT_DIR}/test-failures" ]]; then
        echo "Found test failure marker file"
    # Method 3: Check for non-zero exit codes in test logs (common pattern)
    elif find "${ARTIFACT_DIR}" -name "*test*.log" -type f -exec grep -l "exit code: [1-9]" {} \; 2>/dev/null | head -1 >/dev/null; then
        echo "Found non-zero exit codes in test logs"
    else
        echo "No test failures detected, skipping must-gather collection"
        echo "Use MUST_GATHER_ON_FAILURE_ONLY=false to always collect must-gather"
        exit 0
    fi

    echo "Test failures detected, proceeding with must-gather collection"
fi

echo "Must-gather collection is enabled"
echo "MUST_GATHER_IMAGE: ${MUST_GATHER_IMAGE:-}"
echo "MUST_GATHER_TIMEOUT: ${MUST_GATHER_TIMEOUT:-35m}"
echo "MUST_GATHER_ON_FAILURE_ONLY: ${MUST_GATHER_ON_FAILURE_ONLY:-false}"

# Ensure we have a kubeconfig
if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling must-gather."
	exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
#if test -f "${SHARED_DIR}/proxy-conf.sh"
#then
#	# shellcheck disable=SC1090
#	source "${SHARED_DIR}/proxy-conf.sh"
#fi

# Set up must-gather parameters
MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"35m"}
MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-"registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:latest"}

set -x # log the MG commands
echo "Running sandboxed containers operator must-gather..."
mkdir -p ${ARTIFACT_DIR}/must-gather-osc

# Download the MCO sanitizer binary from mirror
curl -sL "https://mirror.openshift.com/pub/ci/$(arch)/mco-sanitize/mco-sanitize" > /tmp/mco-sanitize
chmod +x /tmp/mco-sanitize

# Run must-gather with the sandboxed containers operator image
oc --insecure-skip-tls-verify adm must-gather \
    --timeout="$MUST_GATHER_TIMEOUT" \
    --dest-dir "${ARTIFACT_DIR}/must-gather-osc" \
    --image="$MUST_GATHER_IMAGE" \
    > "${ARTIFACT_DIR}/must-gather-osc/must-gather.log"

# Sanitize MCO resources to remove sensitive information.
# If the sanitizer fails, fall back to manual redaction.
if ! /tmp/mco-sanitize --input="${ARTIFACT_DIR}/must-gather-osc"; then
  find "${ARTIFACT_DIR}/must-gather-osc" -type f -path '*/cluster-scoped-resources/machineconfiguration.openshift.io/*' -exec sh -c 'echo "REDACTED" > "$1" && mv "$1" "$1.redacted"' _ {} \;
fi                                                                                                                     

# Create compressed archive
tar -czC "${ARTIFACT_DIR}/must-gather-osc" -f "${ARTIFACT_DIR}/must-gather-osc.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather-osc

set +x # stop logging commands

echo "Sandboxed containers operator must-gather collection completed successfully"
echo "Archive created: ${ARTIFACT_DIR}/must-gather-osc.tar.gz"
