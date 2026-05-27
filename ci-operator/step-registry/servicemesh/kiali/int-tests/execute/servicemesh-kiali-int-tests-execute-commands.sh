#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--servicemesh-operator__kiali-int-tests-execute.xml
    ' EXIT
fi

# login for interop
if [ -s "${KUBECONFIG}" ]; then
    oc whoami
else #login for ROSA & Hypershift platforms
    (set +x; eval "$(cat "${SHARED_DIR}/api.login")")
fi

# remove v from ISTIO version if there is any
[[ $ISTIO_SAMPLE_APP_VERSION == v* ]] && ISTIO_SAMPLE_APP_VERSION="${ISTIO_SAMPLE_APP_VERSION#v}" || ISTIO_SAMPLE_APP_VERSION="$ISTIO_SAMPLE_APP_VERSION"
hack/istio/download-istio.sh -iv "${ISTIO_SAMPLE_APP_VERSION}"
# install testing apps
hack/istio/install-testing-demos.sh -c oc -gw true
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

(
  set +x
  make test-integration \
    -e URL="https://$(oc get route -n "${ISTIO_NAMESPACE}" kiali -o 'jsonpath={.spec.host}')" \
    -e TOKEN="$(oc whoami -t)" \
    -e LPINTEROP="true"
)
# Copying result xml to ${ARTIFACT_DIR}
# the file name must start with 'junit'
cp tests/integration/junit-rest-report.xml "${ARTIFACT_DIR}/junit-kiali-int.xml" || true

# cleaning demo apps
hack/istio/install-testing-demos.sh -d true -c oc -in "${ISTIO_NAMESPACE}"
true