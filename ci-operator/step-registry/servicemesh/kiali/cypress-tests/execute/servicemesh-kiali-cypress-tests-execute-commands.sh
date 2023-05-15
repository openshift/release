#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
OCP_CRED_USR="kubeadmin"
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"

oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
hack/istio/install-testing-demos.sh -c oc -in ${SMCP_NAMESPACE}
sleep 120

KIALI_ROUTE=$(oc get route kiali -n ${SMCP_NAMESPACE} -o=jsonpath='{.spec.host}')
export CYPRESS_BASE_URL="https://${KIALI_ROUTE}"
export CYPRESS_USERNAME=${OCP_CRED_USR}
export CYPRESS_PASSWD=${OCP_CRED_PSW}
export CYPRESS_AUTH_PROVIDER="kube:admin"

yarn cypress:run:junit || true # do not fail on a exit code != 0 as it matches number of failed tests
yarn cypress:combine:reports

echo "Copying result xml and screenshots to ${ARTIFACT_DIR}"
# the file name must start with 'junit'
cp cypress/results/combined-report.xml ${ARTIFACT_DIR}/junit-kiali-cypress.xml
cp -r cypress/screenshots ${ARTIFACT_DIR}/ || true

# cleaning demo apps
hack/istio/install-testing-demos.sh -d true -c oc -in ${SMCP_NAMESPACE}
