#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL

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
hack/istio/install-testing-demos.sh -c oc -in ${SMCP_NAMESPACE}
sleep 120
oc wait --for condition=Successful kiali/kiali -n ${SMCP_NAMESPACE} --timeout=250s
oc wait --for condition=available deployment/kiali -n ${SMCP_NAMESPACE} --timeout=250s

KIALI_ROUTE=$(oc get route kiali -n ${SMCP_NAMESPACE} -o=jsonpath='{.spec.host}')
export CYPRESS_BASE_URL="https://${KIALI_ROUTE}"
export CYPRESS_USERNAME=${OCP_CRED_USR}
export CYPRESS_PASSWD=${OCP_CRED_PSW}
export CYPRESS_AUTH_PROVIDER="kube:admin"

# for flaky tests
export CYPRESS_RETRIES=2
export TEST_GROUP="not @crd-validation and not @multi-cluster and not @skip-lpinterop"
yarn cypress:run:test-group:junit || true # do not fail on a exit code != 0 as it matches number of failed tests
# save screenshots from the 1st run
cp -r cypress/screenshots ${ARTIFACT_DIR}/ || true
export TEST_GROUP="@crd-validation and not @multi-cluster and not @skip-lpinterop"
yarn cypress:run:test-group:junit || true # do not fail on a exit code != 0 as it matches number of failed tests

# merge all reports together
yarn cypress:combine:reports

echo "Copying result xml and screenshots to ${ARTIFACT_DIR}"
# the file name must start with 'junit'
cp cypress/results/combined-report.xml ${ARTIFACT_DIR}/junit-kiali-cypress.xml
cp -r cypress/screenshots ${ARTIFACT_DIR}/ || true

# cleaning demo apps
hack/istio/install-testing-demos.sh -d true -c oc -in ${SMCP_NAMESPACE}
