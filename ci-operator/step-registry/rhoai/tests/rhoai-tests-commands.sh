#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login for interop testings
OCP_CRED_USR="kubeadmin"
export OCP_CRED_USR
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
export OCP_CRED_PSW
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

OC_HOST=$(oc whoami --show-server)
OCP_CONSOLE=$(oc whoami --show-console)
RHODS_DASHBOARD="https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}{"\n"}')"

export OC_HOST
export OCP_CONSOLE
export RHODS_DASHBOARD

# running RHOAI tests
./run_interop.sh
