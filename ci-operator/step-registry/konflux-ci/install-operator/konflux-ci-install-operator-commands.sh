#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GITHUB_APP_ID GITHUB_PRIVATE_KEY WEBHOOK_SECRET QUAY_TOKEN QUAY_ORGANIZATION

GITHUB_APP_ID=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/github-app-id)
GITHUB_PRIVATE_KEY=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/github-private-key)
WEBHOOK_SECRET=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/webhook-secret)
QUAY_TOKEN=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/quay-token)
QUAY_ORGANIZATION=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/quay-org)

echo "Installing Konflux on OpenShift..."

echo "Running deploy-konflux-on-ocp.sh..."
./deploy-konflux-on-ocp.sh

echo "Konflux installation complete."
