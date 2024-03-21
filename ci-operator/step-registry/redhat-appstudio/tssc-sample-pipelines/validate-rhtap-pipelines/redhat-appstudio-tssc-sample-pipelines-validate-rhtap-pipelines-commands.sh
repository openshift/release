#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

status=0
DEBUG_OUTPUT=/tmp/log.txt

export OPENSHIFT_API \
  OPENSHIFT_PASSWORD \
  GIT_REPO_URL

ROOT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROX_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
ROX_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)
IMAGE_REPOSITORY=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-default-image-repository)
DOCKER_USERNAME=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-username)
DOCKER_PASSWORD=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-password)
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
GIT_REPO_URL="https://github.com/prietyc123-qe-org/rhtap-go-sample"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"
OPENSHIFT_PASSWORD="$(cat "$KUBEADMIN_PASSWORD_FILE")"

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u kubeadmin -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF

if [ $? -ne 0 ]; then
  echo "Timed out waiting for login"
  exit 1
fi


CONFIG_FILE="$ROOT_DIR/hack/build/build-config.env"
cat <<EOF > "$CONFIG_FILE"
# Set your own build configuration
IMAGE_REPOSITORY="$IMAGE_REPOSITORY"
DOCKER_USERNAME="$DOCKER_USERNAME"
DOCKER_PASSWORD="$DOCKER_PASSWORD"
# Stackrox endpoint to use or "in-cluster" to obtain installed in the cluster ACS route automatically.
ROX_ENDPOINT="${ROX_ENDPOINT:-in-cluster}"
ROX_TOKEN="$ROX_TOKEN"
EOF

wait_for_pipeline() {
    local timeout_seconds=$((15 * 60))
    if ! oc wait --for=condition=succeeded "$1" -n "$2" --timeout "${timeout_seconds}s" >"$DEBUG_OUTPUT"; then
        echo "[ERROR] RHTAP Pipeline failed to complete successful" >&2
        oc get "$1" -n "$2" >"$DEBUG_OUTPUT"
        exit 1
    fi
}

NAMESPACE="test-pipeline$((RANDOM % 10000000))"

echo "Create a new test project"
oc new-project "$NAMESPACE"

echo "Set the newly created project as the current project"
oc project "$NAMESPACE"

echo "Preparing rhtap sample pipelines build resources..."
hack/build/prepare-build-resources.sh || status="$?" || :

echo "Apply the rhtap tasks and pipelines in the test namspace $NAMESPACE..."
oc apply -f "${ROOT_DIR}/pac/tasks"
oc apply -f "${ROOT_DIR}/pac/pipelines/docker-build-rhtap.yaml"

echo "Run the rhtap sample build pipeline..."
hack/build/run-build.sh || status="$?" || :

PIPELINE="${PIPELINE:-docker-build-rhtap}"
wait_for_pipeline "pipelineruns/$PIPELINE" "$NAMESPACE"

exit $status
