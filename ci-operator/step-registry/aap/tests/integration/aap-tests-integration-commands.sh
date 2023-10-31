#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(cat ${SECRETS_DIR}/QUAY_USER)"

echo "Login into the cluster"
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
oc login "https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443" \
  --username="kubeadmin" \
  --password="$(cat ${SHARED_DIR}/kubeadmin-password)" \
  --insecure-skip-tls-verify=true

echo "Run AAP Interop testing..."
AAP_IMAGE_PULLSECRET="aap-secret"
POD_NAME=aap-tests-pod
CONTAINER_NAME=aap-tests-container
IMAGE_NAME=quay.io/aap-ci/ansible-tests-integration-agent

echo "Create pull secrets"
SECRETS_DIR="/tmp/secrets/ci"
oc create secret generic kubeconfig-secret --from-file $SHARED_DIR/kubeconfig
oc create secret docker-registry ${AAP_IMAGE_PULLSECRET} \
    --docker-server=quay.io \
    --docker-username="$(cat ${SECRETS_DIR}/QUAY_USER)" \
    --docker-password="$(cat ${SECRETS_DIR}/QUAY_PWD)"

SNYK_TOKEN="$(cat $SNYK_TOKEN_PATH)"
export SNYK_TOKEN

# install snyk
SNYK_DIR=/tmp/snyk
mkdir -p ${SNYK_DIR}

curl https://static.snyk.io/cli/latest/snyk-linux -o $SNYK_DIR/snyk
chmod +x ${SNYK_DIR}/snyk

echo snyk installed to ${SNYK_DIR}
${SNYK_DIR}/snyk --version

${SNYK_DIR}/snyk container test --username="$(cat ${SECRETS_DIR}/QUAY_USER)" --password="$(cat ${SECRETS_DIR}/QUAY_PWD)" ${IMAGE_NAME} --json-file-output=${ARTIFACT_DIR}/vuln.json
