#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"

# login via kubeconfig which should be available in both standard OCP and ROSA
oc login --kubeconfig=${KUBECONFIG} --insecure-skip-tls-verify=true
hack/istio/install-bookinfo-demo.sh -c oc -n bookinfo -tg -in ${SMCP_NAMESPACE}
sleep 120

make test-integration -e URL="https://$(oc get route -n ${SMCP_NAMESPACE} kiali -o 'jsonpath={.spec.host}')" -e TOKEN="$(oc whoami -t)"

echo "Copying result xml to ${ARTIFACT_DIR}"
# the file name must start with 'junit'
cp tests/integration/junit-rest-report.xml ${ARTIFACT_DIR}/junit-kiali-int.xml

hack/istio/install-bookinfo-demo.sh -db true -c oc -n bookinfo -in ${SMCP_NAMESPACE}

