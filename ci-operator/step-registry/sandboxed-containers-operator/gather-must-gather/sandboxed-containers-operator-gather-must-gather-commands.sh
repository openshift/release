#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Do not enable shell tracing: the step may handle cluster credentials.
resolve_must_gather_image() {
    local image="$1"
    local repository="quay.io/redhat-user-workloads/ose-osc-tenant/osc-must-gather"
    local api_url="https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-must-gather/tag/"
    local page=1 response candidate epoch best_tag="" best_epoch=0 additional

    if [[ "${image}" != "${repository}:latest" ]]; then
        printf '%s\n' "${image}"
        return
    fi

    while (( page <= 100 )); do
        if ! response=$(curl -fsS --retry 3 --max-time 30 "${api_url}?limit=100&page=${page}&onlyActiveTags=true"); then
            echo "ERROR: Could not query Quay for must-gather build tags (page ${page})" >&2
            return 1
        fi
        if ! grep -qE '"tags"[[:space:]]*:[[:space:]]*\[' <<< "${response}" ||
           ! grep -qE '"has_additional"[[:space:]]*:[[:space:]]*(true|false)' <<< "${response}"; then
            echo "ERROR: Invalid Quay tag response (page ${page})" >&2
            return 1
        fi
        # The cli image is not guaranteed to include jq. Select only numeric
        # version-epoch names, excluding PR, signature and architecture tags.
        candidate=$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+"' <<< "${response}" |
            sed -E 's/.*"([0-9]+\.[0-9]+(\.[0-9]+)?-([0-9]+))"/\3 \1/' |
            sort -n -k1,1 | tail -n 1 | cut -d ' ' -f 2 || true)
        if [[ -n "${candidate}" ]]; then
            epoch="${candidate##*-}"
            if (( 10#${epoch} > best_epoch )); then
                best_epoch=$((10#${epoch}))
                best_tag="${candidate}"
            fi
        fi
        additional=$(grep -oE '"has_additional"[[:space:]]*:[[:space:]]*(true|false)' <<< "${response}" | sed -E 's/.*:[[:space:]]*//')
        if [[ "${additional}" == "false" ]]; then
            if [[ -z "${best_tag}" ]]; then
                echo "ERROR: No active version-epoch must-gather build tag found" >&2
                return 1
            fi
            printf '%s:%s\n' "${repository}" "${best_tag}"
            return
        fi
        page=$((page + 1))
    done
    echo "ERROR: Exceeded 100 pages while searching for must-gather build tags" >&2
    return 1
}

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
if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Set up must-gather parameters
MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"35m"}
MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-"quay.io/redhat-user-workloads/ose-osc-tenant/osc-must-gather:latest"}
if [[ -s "${SHARED_DIR}/must-gather-mirrored-image" ]]; then
    echo "Using must-gather image mirrored during cluster setup"
    MUST_GATHER_IMAGE=$(cat "${SHARED_DIR}/must-gather-mirrored-image")
else
    MUST_GATHER_IMAGE=$(resolve_must_gather_image "${MUST_GATHER_IMAGE}")
fi
echo "Resolved must-gather image: ${MUST_GATHER_IMAGE}"

echo "Running sandboxed containers operator must-gather..."
mkdir -p "${ARTIFACT_DIR}/must-gather-osc"

# Download the MCO sanitizer binary from mirror
curl -sL "https://openshift-mirror-list.ci-systems.workers.dev/pub/ci/$(arch)/mco-sanitize/mco-sanitize" > /tmp/mco-sanitize
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

echo "Sandboxed containers operator must-gather collection completed successfully"
echo "Archive created: ${ARTIFACT_DIR}/must-gather-osc.tar.gz"
