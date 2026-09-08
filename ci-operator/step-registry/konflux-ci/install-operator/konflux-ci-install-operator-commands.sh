#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Handle Gangway API override for OPERATOR_IMAGE
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE:-}" ]]; then
    export OPERATOR_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE}"
    # Derive KONFLUX_REF from image tag (e.g., quay.io/org/image:v0.1.5 -> v0.1.5)
    KONFLUX_REF="${OPERATOR_IMAGE##*:}"
    echo "Gangway override: OPERATOR_IMAGE=${OPERATOR_IMAGE}"
    echo "Derived KONFLUX_REF=${KONFLUX_REF} from image tag"
fi

# If KONFLUX_REF is set, checkout that ref to align scripts/manifests with the image
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

export GITHUB_APP_ID GITHUB_PRIVATE_KEY WEBHOOK_SECRET QUAY_TOKEN QUAY_ORGANIZATION SMEE_CHANNEL

GITHUB_APP_ID=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/github-app-id)
GITHUB_PRIVATE_KEY=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/github-private-key)
WEBHOOK_SECRET=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/webhook-secret)
QUAY_TOKEN=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/quay-token)
QUAY_ORGANIZATION=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/quay-org)
SMEE_CHANNEL=$(cat /usr/local/ci-secrets/konflux-ci-konflux-ci-e2e-tests-credentials/smee-channel)

echo "Installing Konflux on OpenShift..."

echo "Running deploy-konflux-on-ocp.sh..."
./deploy-konflux-on-ocp.sh

echo "Konflux installation complete."
