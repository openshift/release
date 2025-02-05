#!/bin/bash
set -e

# Define the default image from OpenShift CI mirror
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

# If changes are detected, build the image locally
if [ "$IMAGE_BUILD_NEEDED" = true ]; then
    echo "Changes detected in .ibm/images/. Building local image..."
    podman build -t $LOCAL_IMAGE .ibm/images/
    export RHDH_E2E_RUNNER_IMAGE=$LOCAL_IMAGE
else
    echo "No changes in .ibm/images/. Using mirrored image from OpenShift CI."
    export RHDH_E2E_RUNNER_IMAGE=$MIRRORED_IMAGE
fi

# Save the selected image variable for use in OpenShift CI jobs
echo "RHDH_E2E_RUNNER_IMAGE=$RHDH_E2E_RUNNER_IMAGE" > "$WORKSPACE/env_vars"
