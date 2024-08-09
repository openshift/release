#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

sleep 2h


#Do something like:
#ECLIPSE_CHE_URL=$(oc get route -n "${CHE_NAMESPACE}" che -o jsonpath='{.status.ingress[0].host}')}
#and
#sed -i "s@TS_SELENIUM_BASE_URL@${ECLIPSE_CHE_URL}@g"  quay.io/eclipse/e2e-che-interop:latest


#CONSOLE_URL=$(cat $SHARED_DIR/console.url)
#export CONSOLE_URL
#OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
#export OCP_API_URL
#
## login for interop
#if test -f ${SHARED_DIR}/kubeadmin-password
#then
#  OCP_CRED_USR="kubeadmin"
#  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
#  oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
#else #login for ROSA & Hypershift platforms
#  eval "$(cat "${SHARED_DIR}/api.login")"
#fi

