#!/usr/bin/env bash

set -e

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  echo "SHARED:"
  OCP_CRED_USR="kubeadmin"
  export OCP_CRED_USR
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  export OCP_CRED_PSW
  oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  echo "SHARE2"
  eval "$(cat "${SHARED_DIR}/api.login")"
fi
echo "SHARED: ${SHARED_DIR}/kubeadmin-password" || true
echo "SHARED1: $(cat ${SHARED_DIR}/api.login)" || true

cd /tmp/devspaces/scripts
#cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ./
cp -v "${KUBECONFIG}" ./

./execute-test-harness.sh

cp -r /tmp/devspaces/scripts/test-run-results ${ARTIFACT_DIR}