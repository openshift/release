#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

# download the istio version with 1.19.1 bookinfo app
hack/istio/download-istio.sh -iv 1.22.3
hack/istio/install-bookinfo-demo.sh -c oc -n bookinfo -tg -in ${SMCP_NAMESPACE}
sleep 120
oc wait --for condition=Successful kiali/kiali -n ${SMCP_NAMESPACE} --timeout=250s
oc wait --for condition=available deployment/kiali -n ${SMCP_NAMESPACE} --timeout=250s

TOKEN="$(oc whoami -t)"
echo "TOKEN=$TOKEN"

make test-integration -e URL="https://$(oc get route -n ${SMCP_NAMESPACE} kiali -o 'jsonpath={.spec.host}')" -e TOKEN="$(oc whoami -t)"

echo "Copying result xml to ${ARTIFACT_DIR}"
# the file name must start with 'junit'
cp tests/integration/junit-rest-report.xml ${ARTIFACT_DIR}/junit-kiali-int.xml

hack/istio/install-bookinfo-demo.sh -db true -c oc -n bookinfo -in ${SMCP_NAMESPACE}

