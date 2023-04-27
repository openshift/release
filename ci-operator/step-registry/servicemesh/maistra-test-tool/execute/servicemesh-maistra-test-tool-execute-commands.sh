#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_CRED_USR="kubeadmin"
export OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"

make test

echo "Copying logs and xmls to ${ARTIFACT_DIR}"
cp tests/result-latest/* ${ARTIFACT_DIR}
