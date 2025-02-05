#!/bin/bash
set -e

echo "🔄 Checking if PR is merged before pushing to Quay.io..."

# Ensure we only push images after a PR is merged
if [ "$JOB_TYPE" != "postsubmit" ]; then
    echo "🔄 PR is not merged. Skipping image push to Quay.io."
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Call select-image.sh to determine the image used
bash "$REPO_ROOT/ci-operator/step-registry/redhat-developer/rhdh/select-image.sh"

# If the local image was built, push it to Quay.io
if [ "$RHDH_E2E_RUNNER_IMAGE" = "rhdh-e2e-runner-temp" ]; then
    echo "🚀 Changes detected in .ibm/images/. Pushing new image to Quay.io..."

    podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io
    podman tag rhdh-e2e-runner-temp quay.io/rhdh-community/rhdh-e2e-runner:latest
    podman push quay.io/rhdh-community/rhdh-e2e-runner:latest

    echo "Image successfully pushed to quay.io/rhdh-community/rhdh-e2e-runner:latest"
else
    echo "No changes detected in .ibm/images/. No push needed."
fi
