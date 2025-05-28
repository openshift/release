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

BUCKET_INFO="/tmp/secrets/ci"
ENDPOINT_1="$(cat ${BUCKET_INFO}/ENDPOINT_1)"
ENDPOINT_2="$(cat ${BUCKET_INFO}/ENDPOINT_2)"
REGION_1="$(cat ${BUCKET_INFO}/REGION_1)"
REGION_2="$(cat ${BUCKET_INFO}/REGION_2)"
NAME_1="$(cat ${BUCKET_INFO}/NAME_1)"
NAME_2="$(cat ${BUCKET_INFO}/NAME_2)"
NAME_3="$(cat ${BUCKET_INFO}/NAME_3)"
NAME_4="$(cat ${BUCKET_INFO}/NAME_4)"
NAME_5="$(cat ${BUCKET_INFO}/NAME_5)"

export ENDPOINT_1
export ENDPOINT_2
export REGION_1
export REGION_2
export NAME_1
export NAME_2
export NAME_3
export NAME_4
export NAME_5

# running RHOAI tests
./run_interop.sh || true

sleep 2h
