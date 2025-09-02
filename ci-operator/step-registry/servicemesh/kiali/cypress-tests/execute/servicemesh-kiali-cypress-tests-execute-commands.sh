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

if [ "${OSSM_VERSION}" == "2" ]
then
  # download istio samples
  hack/istio/download-istio.sh -iv 1.22.3
  # install demo apps
  hack/istio/install-testing-demos.sh -c oc -in ${ISTIO_NAMESPACE}
elif [ "${OSSM_VERSION}" == "3" ]
then
  # remove v from ISTIO version if there is any
  [[ $ISTIO_VERSION == v* ]] && ISTIO_VERSION="${ISTIO_VERSION#v}" || ISTIO_VERSION="$ISTIO_VERSION"
  hack/istio/download-istio.sh -iv ${ISTIO_VERSION}
  # install testing apps
  hack/istio/install-testing-demos.sh -c oc -in ${ISTIO_NAMESPACE}
  # enable monitoring in demo apps
  hack/use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -n alpha -ml ossm-3 -kcns ${ISTIO_NAMESPACE} -np false
  hack/use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -n beta -ml ossm-3 -kcns ${ISTIO_NAMESPACE} -np false
  hack/use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -n gamma -ml ossm-3 -kcns ${ISTIO_NAMESPACE} -np false
  hack/use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -n default -ml ossm-3 -kcns ${ISTIO_NAMESPACE} -np false
  hack/use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -n bookinfo -ml ossm-3 -kcns ${ISTIO_NAMESPACE} -np false
  hack/use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -n sleep -ml ossm-3 -kcns ${ISTIO_NAMESPACE} -np false
  # install custom grafana
  oc apply -n ${ISTIO_NAMESPACE} -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/grafana.yaml
  oc wait -n ${ISTIO_NAMESPACE} --for=condition=available deployment/grafana --timeout=150s
  # Expose grafana route (for Kiali) (delete route first if exists from previous run)
  oc delete -n ${ISTIO_NAMESPACE} route grafana || true
  oc expose -n ${ISTIO_NAMESPACE} service grafana --name=grafana
  sleep 5s
  GRAFANA_URL=$(oc get route grafana -o jsonpath='{.spec.host}' -n ${ISTIO_NAMESPACE})
  oc patch kiali kiali -n ${ISTIO_NAMESPACE} -p "{\"spec\":{\"external_services\":{\"grafana\": {\"internal_url\": \"http://grafana.${ISTIO_NAMESPACE}:3000\"}}}}" --type=merge
  oc patch kiali kiali -n ${ISTIO_NAMESPACE} -p "{\"spec\":{\"external_services\":{\"grafana\": {\"external_url\": \"http://${GRAFANA_URL}\"}}}}" --type=merge
  oc patch kiali kiali -n ${ISTIO_NAMESPACE} -p "{\"spec\":{\"external_services\":{\"grafana\": {\"enabled\": true}}}}" --type=merge
else
  echo "Unsuported OSSM_VERSION ${OSSM_VERSION}!"
  exit 1
fi

sleep 120
oc wait --for condition=Successful kiali/kiali -n ${ISTIO_NAMESPACE} --timeout=250s
oc wait --for condition=available deployment/kiali -n ${ISTIO_NAMESPACE} --timeout=250s

KIALI_ROUTE=$(oc get route kiali -n ${ISTIO_NAMESPACE} -o=jsonpath='{.spec.host}')
export CYPRESS_BASE_URL="https://${KIALI_ROUTE}"
export CYPRESS_USERNAME=${OCP_CRED_USR}
export CYPRESS_PASSWD=${OCP_CRED_PSW}
export CYPRESS_AUTH_PROVIDER="kube:admin"

# for flaky tests
export CYPRESS_RETRIES=2
export TEST_GROUP="not @crd-validation and not @multi-cluster and not @smoke and not @ambient and not @waypoint and (not @waypoint-tracing or @tracing) and not @cytoscape and not @skip-lpinterop"
yarn cypress:run:test-group:junit || true # do not fail on a exit code != 0 as it matches number of failed tests
# save screenshots from the 1st run
cp -r cypress/screenshots ${ARTIFACT_DIR}/ || true
export TEST_GROUP="@crd-validation and not @multi-cluster and not @smoke and not @ambient and not @waypoint and (not @waypoint-tracing or @tracing) and not @cytoscape and not @skip-lpinterop"
yarn cypress:run:test-group:junit || true # do not fail on a exit code != 0 as it matches number of failed tests

# merge all reports together
yarn cypress:combine:reports

echo "Copying result xml and screenshots to ${ARTIFACT_DIR}"
# the file name must start with 'junit'
cp cypress/results/combined-report.xml ${ARTIFACT_DIR}/junit-kiali-cypress.xml
cp -r cypress/screenshots ${ARTIFACT_DIR}/ || true
cp -r /tmp/kiali/cypress/screenshots ${ARTIFACT_DIR}/ || true

# cleaning demo apps
hack/istio/install-testing-demos.sh -d true -c oc -in ${ISTIO_NAMESPACE}
