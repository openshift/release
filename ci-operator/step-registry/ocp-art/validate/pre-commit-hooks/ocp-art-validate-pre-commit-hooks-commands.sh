#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== rh-pre-commit Sign-off Validation ==="
echo "Checking that all PR commit messages include rh-pre-commit sign-off..."

if [ -z "${PULL_BASE_SHA:-}" ]; then
    echo "PULL_BASE_SHA is not set. This check only runs in presubmit (PR) context."
    echo "Skipping validation."
    exit 0
fi

COMMITS=$(git rev-list --no-merges "${PULL_BASE_SHA}..HEAD" 2>/dev/null || true)

if [ -z "${COMMITS}" ]; then
    echo "No non-merge commits found in range ${PULL_BASE_SHA}..HEAD"
    echo "Nothing to validate."
    exit 0
fi

COMMIT_COUNT=$(echo "${COMMITS}" | wc -l | tr -d ' ')
echo "Found ${COMMIT_COUNT} non-merge commit(s) to check."
echo ""

FAILED=0
FAILED_COMMITS=""

for commit in ${COMMITS}; do
    MSG=$(git log -1 --format="%B" "${commit}")
    SHORT=$(git log -1 --format="%h %s" "${commit}")

    MISSING_VERSION=false
    MISSING_SECRETS=false

    if ! echo "${MSG}" | grep -q "rh-pre-commit\.version:"; then
        MISSING_VERSION=true
    fi

    if ! echo "${MSG}" | grep -q "rh-pre-commit\.check-secrets: ENABLED"; then
        MISSING_SECRETS=true
    fi

    if [ "${MISSING_VERSION}" = "true" ] || [ "${MISSING_SECRETS}" = "true" ]; then
        echo "FAIL: ${SHORT}"
        if [ "${MISSING_VERSION}" = "true" ]; then
            echo "  - Missing: rh-pre-commit.version: <version>"
        fi
        if [ "${MISSING_SECRETS}" = "true" ]; then
            echo "  - Missing: rh-pre-commit.check-secrets: ENABLED"
        fi
        FAILED=1
        FAILED_COMMITS="${FAILED_COMMITS}  - ${SHORT}\n"
    else
        echo "OK:   ${SHORT}"
    fi
done

echo ""
echo "=== Summary ==="

if [ "${FAILED}" -eq 1 ]; then
    echo "FAILED: One or more commits are missing the rh-pre-commit sign-off."
    echo ""
    echo "Commits missing sign-off:"
    echo -e "${FAILED_COMMITS}"
    echo "The rh-pre-commit tool must be installed with the sign-off flag (-s) enabled."
    echo "When configured correctly, it appends these lines to each commit message:"
    echo "  rh-pre-commit.version: <version>"
    echo "  rh-pre-commit.check-secrets: ENABLED"
    echo ""
    echo "Install rh-pre-commit:"
    echo "  https://gitlab.cee.redhat.com/infosec-public/developer-workbench/tools/-/tree/main/rh-pre-commit#quickstart-install"
    exit 1
fi

echo "All ${COMMIT_COUNT} commit(s) have valid rh-pre-commit sign-off."
echo "=== Validation Passed ==="
