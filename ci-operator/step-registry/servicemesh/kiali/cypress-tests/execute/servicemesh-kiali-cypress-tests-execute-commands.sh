#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--servicemesh-operator__kiali-cypress-tests-execute.xml
    ' EXIT
fi

typeset ocpCredUsr=''
typeset ocpCredPsw=''

# login for interop
if [ -s "${KUBECONFIG}" ]; then
    oc whoami
    ocpCredUsr="kubeadmin"
    ocpCredPsw="$(set +x; cat "${SHARED_DIR}/kubeadmin-password")"
else #login for ROSA & Hypershift platforms
    (set +x; eval "$(cat "${SHARED_DIR}/api.login")")
fi

# remove v from ISTIO version if there is any
[[ $ISTIO_SAMPLE_APP_VERSION == v* ]] && ISTIO_SAMPLE_APP_VERSION="${ISTIO_SAMPLE_APP_VERSION#v}" || ISTIO_SAMPLE_APP_VERSION="$ISTIO_SAMPLE_APP_VERSION"
hack/istio/download-istio.sh -iv "${ISTIO_SAMPLE_APP_VERSION}"
# install testing apps
hack/istio/install-testing-demos.sh -c oc -in "${ISTIO_NAMESPACE}"
# wait till all apps are ready
typeset namespace=''
for namespace in alpha beta bookinfo sleep
do
  oc wait --for=condition=Ready pods --all -n "${namespace}" --timeout 60s || true
  oc wait --for=condition=Ready pods --all -n "${namespace}" --timeout 60s || (oc get pods -n "${namespace}"; oc describe pods -n "${namespace}"; exit 1)
done
# enable monitoring in demo apps
hack/use-openshift-prometheus.sh -in "${ISTIO_NAMESPACE}" -n "alpha beta default bookinfo sleep" -ml ossm-3 -kcns "${ISTIO_NAMESPACE}" -np false
# install custom grafana
oc apply -n "${ISTIO_NAMESPACE}" -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_SAMPLE_APP_VERSION}/samples/addons/grafana.yaml"
oc wait -n "${ISTIO_NAMESPACE}" --for=condition=available deployment/grafana --timeout=150s
# Expose grafana route (for Kiali) (delete route first if exists from previous run)
oc delete -n "${ISTIO_NAMESPACE}" route grafana || true
oc expose -n "${ISTIO_NAMESPACE}" service grafana --name=grafana
sleep 5s
GRAFANA_URL="$(oc get route grafana -o jsonpath='{.spec.host}' -n "${ISTIO_NAMESPACE}")"
oc patch kiali kiali -n "${ISTIO_NAMESPACE}" -p "{\"spec\":{\"external_services\":{\"grafana\": {\"internal_url\": \"http://grafana.${ISTIO_NAMESPACE}:3000\"}}}}" --type=merge
oc patch kiali kiali -n "${ISTIO_NAMESPACE}" -p "{\"spec\":{\"external_services\":{\"grafana\": {\"external_url\": \"http://${GRAFANA_URL}\"}}}}" --type=merge
oc patch kiali kiali -n "${ISTIO_NAMESPACE}" -p "{\"spec\":{\"external_services\":{\"grafana\": {\"enabled\": true}}}}" --type=merge

sleep 120
oc wait --for condition=Successful kiali/kiali -n "${ISTIO_NAMESPACE}" --timeout=250s
oc wait --for condition=available deployment/kiali -n "${ISTIO_NAMESPACE}" --timeout=250s

KIALI_ROUTE="$(oc get route kiali -n "${ISTIO_NAMESPACE}" -o=jsonpath='{.spec.host}')"
export CYPRESS_BASE_URL="https://${KIALI_ROUTE}"
export CYPRESS_USERNAME=${ocpCredUsr}
export CYPRESS_PASSWD=${ocpCredPsw}
export CYPRESS_AUTH_PROVIDER="kube:admin"

# for flaky tests
export CYPRESS_RETRIES=2
export TEST_GROUP="@lpinterop"
yarn cypress:run:test-group:junit || true # do not fail on a exit code != 0 as it matches number of failed tests
# save screenshots from the 1st run
cp -r cypress/screenshots "${ARTIFACT_DIR}/" || true
export TEST_GROUP="@crd-validation and not @multi-cluster and not @smoke and not @ambient and not @waypoint and not @waypoint-tracing and not @tracing and not @cytoscape"
yarn cypress:run:test-group:junit || true # do not fail on a exit code != 0 as it matches number of failed tests

# merge all reports together
yarn cypress:combine:reports

# Copying result xml and screenshots to ${ARTIFACT_DIR}
# the file name must start with 'junit'
cp cypress/results/combined-report.xml "${ARTIFACT_DIR}/junit-kiali-cypress.xml" || true
cp -r cypress/screenshots "${ARTIFACT_DIR}/" || true
cp -r /tmp/kiali/cypress/screenshots "${ARTIFACT_DIR}/" || true

# cleaning demo apps
hack/istio/install-testing-demos.sh -d true -c oc -in "${ISTIO_NAMESPACE}"
true