#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

status=0
export OPENSHIFT_API \
  OPENSHIFT_PASSWORD \
  GIT_REPO_URL \
  EVENT_TYPE

ROOT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROX_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
ROX_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)
IMAGE_REPOSITORY=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-default-image-repository)
DOCKER_USERNAME=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-username)
DOCKER_PASSWORD=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-password)
EVENT_TYPE=${EVENT_TYPE:-'push'}
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

echo "Run the rhtap sample build pipeline test..."
test/validate-pipeline.sh || status="$?" || :

exit $status
