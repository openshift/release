#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

