#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL

# for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
  echo "Execute maistra tests"
  make test
else #for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
  ROSA=true make test
fi

echo "Copying logs and xmls to ${ARTIFACT_DIR}"
cp -r tests/result-latest/* ${ARTIFACT_DIR}
# the junit file name must start with 'junit'
cp tests/result-latest/**/report.xml ${ARTIFACT_DIR}/junit-maistra.xml

make test-cleanup
