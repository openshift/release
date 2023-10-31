#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Run secuirty vulnerability testing..."
IMAGE_NAME=quay.io/aap-ci/ansible-tests-integration-agent

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

echo Full vulnerabilities report is available at ${ARTIFACT_DIR}/vuln.json

