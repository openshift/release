#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
OCP_CRED_USR="kubeadmin"
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"

export OCP_API_URL
export OCP_CRED_USR
export OCP_CRED_PSW

make test

echo "Copying logs and xmls to ${ARTIFACT_DIR}"
cp -r tests/result-latest/* ${ARTIFACT_DIR}
# the junit file name must start with 'junit'
cp tests/result-latest/**/report.xml ${ARTIFACT_DIR}/junit-maistra.xml

make test-cleanup
