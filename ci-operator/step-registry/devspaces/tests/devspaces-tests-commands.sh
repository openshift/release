#!/usr/bin/env bash

set -e

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login for interop testings
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  export OCP_CRED_USR
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  export OCP_CRED_PSW
  oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

cd /tmp/devspaces/scripts
cp -v "${KUBECONFIG}" ./

./execute-test-harness.sh

cp -r /tmp/devspaces/scripts/test-run-results ${ARTIFACT_DIR}