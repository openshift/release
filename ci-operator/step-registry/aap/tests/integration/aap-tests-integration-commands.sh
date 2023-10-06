#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Create secrets"
SECRETS_DIR="/tmp/secrets/ci"

echo $(cat ${SECRETS_DIR}/QUAY_USER)

#SNYK_DIR="/snyk-credentials"

SNYK_TOKEN="$(cat $SNYK_TOKEN_PATH)"
export SNYK_TOKEN

# install snyk
SNYK_DIR=/tmp/snyk
mkdir -p ${SNYK_DIR}

curl https://static.snyk.io/cli/latest/snyk-linux -o $SNYK_DIR/snyk
chmod +x ${SNYK_DIR}/snyk

echo snyk installed to ${SNYK_DIR}
${SNYK_DIR}/snyk --version

