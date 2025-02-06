#!/bin/bash
set -e

# Define default image
MIRRORED_IMAGE="registry.ci.openshift.org/ci/rhdh-e2e-runner:latest"
LOCAL_IMAGE="rhdh-e2e-runner-temp"

# Check for changes in .ibm/images/
PR_CHANGESET=$(git diff --name-only main)
IMAGE_BUILD_NEEDED=false

for change in $PR_CHANGESET; do
    if echo "$change" | grep -qE "^.ibm/images/"; then
        IMAGE_BUILD_NEEDED=true
        break
    fi
done

# Define the correct image
if [ "$IMAGE_BUILD_NEEDED" = true ]; then
    echo "🚀 Changes detected in .ibm/images/. Building local image..."
    podman build -t $LOCAL_IMAGE .ibm/images/
    echo "RHDH_E2E_RUNNER_IMAGE=$LOCAL_IMAGE" >> "$SHARED_DIR/env_vars"
else
    echo "✅ No changes in .ibm/images/. Using mirrored image from OpenShift CI."
    echo "RHDH_E2E_RUNNER_IMAGE=$MIRRORED_IMAGE" >> "$SHARED_DIR/env_vars"
fi
