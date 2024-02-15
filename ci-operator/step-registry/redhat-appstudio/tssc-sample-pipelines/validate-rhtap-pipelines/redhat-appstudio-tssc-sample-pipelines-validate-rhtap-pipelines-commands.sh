#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

status=0
DEBUG_OUTPUT=/tmp/log.txt

ROOT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

ROX_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
ROX_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)
IMAGE_REPOSITORY=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-default-image-repository)
DOCKER_USERNAME=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-username)
DOCKER_PASSWORD=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-password)

CONFIG_FILE="$ROOT_DIR/hack/build/build-config.env"
cat <<EOF > "$CONFIG_FILE"
---
# Set your own build configuration

IMAGE_REPOSITORY="{$IMAGE_REPOSITORY}$((RANDOM % 100000000))"
DOCKER_USERNAME="$DOCKER_USERNAME"
DOCKER_PASSWORD="$DOCKER_PASSWORD"

# Stackrox endpoint to use or "in-cluster" to obtain installed in the cluster ACS route automatically.
ROX_ENDPOINT="${ROX_ENDPOINT:-in-cluster}"
ROX_TOKEN="$ROX_TOKEN"
EOF

wait_for_pipeline() {
    local timeout_seconds=$((10 * 60))
    if ! oc wait --for=condition=succeeded "$1" -n "$2" --timeout "${timeout_seconds}s" >"$DEBUG_OUTPUT"; then
        echo "[ERROR] RHTAP Pipeline failed to complete successful" >&2
        oc get pipelineruns "$1" -n "$2" >"$DEBUG_OUTPUT"
        exit 1
    fi
}

namespace="test-pipeline$((RANDOM % 10000000))"

echo "Create a new test project"
oc new-project $namespace

echo "Set the newly created project as the current project"
oc project $namespace

echo "Preparing rhtap sample pipelines build resources..."
hack/build/prepare-build-resources.sh || status="$?" || :

echo "Apply the rhtap tasks and pipelines in the test namspace $namespace..."
oc apply -f "${ROOT_DIR}/pac/tasks"
oc apply -f "${ROOT_DIR}/pac/pipelines"

echo "Run the rhtap sample build pipeline..."
hack/build/run-build.sh || status="$?" || :

PIPELINE="${PIPELINE:-docker-build-rhtap}"
wait_for_pipeline "pipelineruns/$PIPELINE" $namespace

exit $status