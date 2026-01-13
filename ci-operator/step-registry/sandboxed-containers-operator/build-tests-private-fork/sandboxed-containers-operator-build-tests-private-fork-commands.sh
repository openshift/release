#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "============================================"
echo "Building openshift-tests-private from fork"
echo "============================================"

# Check for GitHub token
# The secret is at selfservice/sandboxed-containers-operator-ci-secrets/otp-fork with key "oauth"
# When mounted, the KEY NAME becomes the filename: /var/run/secrets/github/oauth
GITHUB_TOKEN_FILE="/var/run/secrets/github/oauth"
if [[ -f "${GITHUB_TOKEN_FILE}" ]]; then
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_FILE}")
    echo "GitHub token found, will use authenticated clone"
    CLONE_URL="https://${GITHUB_TOKEN}@github.com/${TESTS_PRIVATE_FORK_ORG}/openshift-tests-private.git"
else
    echo "WARNING: No GitHub token found at ${GITHUB_TOKEN_FILE}"
    echo "Attempting unauthenticated clone (will fail for private repos)"
    CLONE_URL="https://github.com/${TESTS_PRIVATE_FORK_ORG}/openshift-tests-private.git"
fi

# Clone the fork
TESTS_PRIVATE_DIR="/tmp/openshift-tests-private"
echo "Cloning from: https://github.com/${TESTS_PRIVATE_FORK_ORG}/openshift-tests-private.git"
echo "Branch: ${TESTS_PRIVATE_FORK_BRANCH}"

git clone --depth=1 --branch="${TESTS_PRIVATE_FORK_BRANCH}" \
    "${CLONE_URL}" \
    "${TESTS_PRIVATE_DIR}"

cd "${TESTS_PRIVATE_DIR}"

# Log git info for verification
echo ""
echo "=== Fork Information ==="
echo "Fork: https://github.com/${TESTS_PRIVATE_FORK_ORG}/openshift-tests-private"
echo "Branch: ${TESTS_PRIVATE_FORK_BRANCH}"
echo "Commit: $(git rev-parse HEAD)"
echo "Commit Date: $(git log -1 --format=%ci)"
echo "Commit Msg: $(git log -1 --format=%s)"
echo "========================"

# Save git info to shared dir for later steps
{
    echo "Fork: https://github.com/${TESTS_PRIVATE_FORK_ORG}/openshift-tests-private"
    echo "Branch: ${TESTS_PRIVATE_FORK_BRANCH}"
    echo "Commit: $(git rev-parse HEAD)"
    echo "Date: $(git log -1 --format=%ci)"
    echo "Message: $(git log -1 --format=%s)"
} > "${SHARED_DIR}/tests-private-fork-info.txt"

# Build
echo ""
echo "Building extended-platform-tests..."
make go-mod-tidy
make all

# Copy binary to shared dir
cp ./bin/extended-platform-tests "${SHARED_DIR}/"
chmod +x "${SHARED_DIR}/extended-platform-tests"

echo ""
echo "Binary saved to ${SHARED_DIR}/extended-platform-tests"
ls -la "${SHARED_DIR}/extended-platform-tests"

# Mark that fork binary should be used
echo "true" > "${SHARED_DIR}/use-tests-private-fork"

echo ""
echo "Build complete!"
