#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Handle Gangway API override - derive KONFLUX_REF from OPERATOR_IMAGE tag
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE:-}" ]]; then
    # Derive KONFLUX_REF from image tag (e.g., quay.io/org/image:v0.1.5 -> v0.1.5)
    KONFLUX_REF="${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE##*:}"
    echo "Derived KONFLUX_REF=${KONFLUX_REF} from Gangway override"
fi

# If KONFLUX_REF is set, checkout that ref to align test code with the image
if [[ -n "${KONFLUX_REF:-}" ]]; then
    echo "Checking out KONFLUX_REF: ${KONFLUX_REF}"
    git fetch --tags origin 2>/dev/null || true
    git fetch --unshallow origin 2>/dev/null || true
    git checkout "${KONFLUX_REF}" || {
        echo "ERROR: Failed to checkout ${KONFLUX_REF}"
        exit 1
    }
    echo "Successfully checked out ${KONFLUX_REF}"
fi

SECRETS_DIR=/usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials

# Source the e2e env template to pick up defaults
source test/e2e/e2e.env.template

# Override e2e test credentials
export GH_TOKEN GH_ORG QUAY_DOCKERCONFIGJSON RELEASE_CATALOG_TA_QUAY_TOKEN GITHUB_TOKEN MY_GITHUB_ORG
GH_TOKEN=$(cat "${SECRETS_DIR}/github-token")
GH_ORG=$(cat "${SECRETS_DIR}/github-org")
QUAY_DOCKERCONFIGJSON=$(cat "${SECRETS_DIR}/quay-dockerconfigjson")
RELEASE_CATALOG_TA_QUAY_TOKEN=$(cat "${SECRETS_DIR}/release-catalog-ta-quay-token")
GITHUB_TOKEN="${GH_TOKEN}"
MY_GITHUB_ORG="${GH_ORG}"
# Not running with upstream dependencies — this is OCP
unset TEST_ENVIRONMENT

# Deploy test resources and run E2E conformance tests
./test/e2e/run-e2e.sh

