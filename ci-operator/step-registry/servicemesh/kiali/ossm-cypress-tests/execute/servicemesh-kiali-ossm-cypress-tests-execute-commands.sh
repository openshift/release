#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
            -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            install_yq_if_not_exists
            echo "Mapping Kiali Test Suite Name To: ServiceMesh-lp-interop"
            yq eval -px -ox -iI0 '.testsuites.testsuite[]."+@name" = "ServiceMesh-lp-interop"' "${results_file}" || echo "Warning: yq failed for ${results_file}, debug manually" >&2
        fi
    fi
}

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

# download hack from kiali repo
hack/download-hack-scripts.sh --kiali-branch ${KIALI_VERSION}
# download prometheus script
wget -N https://raw.githubusercontent.com/kiali/kiali/${KIALI_VERSION}/hack/use-openshift-prometheus.sh -O _output/kiali/hack/use-openshift-prometheus.sh
chmod +x _output/kiali/hack/use-openshift-prometheus.sh

# remove v from ISTIO version if there is any
[[ $ISTIO_SAMPLE_APP_VERSION == v* ]] && ISTIO_SAMPLE_APP_VERSION="${ISTIO_SAMPLE_APP_VERSION#v}" || ISTIO_SAMPLE_APP_VERSION="$ISTIO_SAMPLE_APP_VERSION"
_output/kiali/hack/istio/download-istio.sh -iv ${ISTIO_SAMPLE_APP_VERSION}
# install testing apps
_output/kiali/hack/istio/install-testing-demos.sh -c oc -in ${ISTIO_NAMESPACE}
# wait till all apps are ready
for namespace in alpha beta gamma bookinfo sleep
do
  oc wait --for=condition=Ready pods --all -n ${namespace} --timeout 60s || true
  oc wait --for=condition=Ready pods --all -n ${namespace} --timeout 60s || (oc get pods -n ${namespace}; oc describe pods -n ${namespace}; exit 1)
done
# enable monitoring in demo apps
_output/kiali/hack//use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -n "alpha beta gamma default bookinfo sleep" -ml ossm-3 -kcns ${ISTIO_NAMESPACE} -np false
# install custom grafana
oc apply -n ${ISTIO_NAMESPACE} -f https://raw.githubusercontent.com/istio/istio/${ISTIO_SAMPLE_APP_VERSION}/samples/addons/grafana.yaml
oc wait -n ${ISTIO_NAMESPACE} --for=condition=available deployment/grafana --timeout=150s
# Expose grafana route (for Kiali) (delete route first if exists from previous run)
oc delete -n ${ISTIO_NAMESPACE} route grafana || true
oc expose -n ${ISTIO_NAMESPACE} service grafana --name=grafana
sleep 5s
GRAFANA_URL=$(oc get route grafana -o jsonpath='{.spec.host}' -n ${ISTIO_NAMESPACE})
oc patch kiali kiali -n ${ISTIO_NAMESPACE} -p "{\"spec\":{\"external_services\":{\"grafana\": {\"internal_url\": \"http://grafana.${ISTIO_NAMESPACE}:3000\"}}}}" --type=merge
oc patch kiali kiali -n ${ISTIO_NAMESPACE} -p "{\"spec\":{\"external_services\":{\"grafana\": {\"external_url\": \"http://${GRAFANA_URL}\"}}}}" --type=merge
oc patch kiali kiali -n ${ISTIO_NAMESPACE} -p "{\"spec\":{\"external_services\":{\"grafana\": {\"enabled\": true}}}}" --type=merge

sleep 120
oc wait --for condition=Successful kiali/kiali -n ${ISTIO_NAMESPACE} --timeout=250s
oc wait --for condition=available deployment/kiali -n ${ISTIO_NAMESPACE} --timeout=250s

export CYPRESS_BASE_URL="${CONSOLE_URL}"
export CYPRESS_USERNAME=${OCP_CRED_USR}
export CYPRESS_PASSWD=${OCP_CRED_PSW}
export CYPRESS_AUTH_PROVIDER="kube:admin"

# for flaky tests
export CYPRESS_RETRIES=2
export TEST_GROUP="@smoke and @ossmc and not @skip-lpinterop"
yarn cypress:run:test-group:junit || true # do not fail on a exit code != 0 as it matches number of failed tests
# save screenshots from the 1st run
cp -r cypress/screenshots ${ARTIFACT_DIR}/ || true

# merge all reports together
yarn cypress:combine:reports

echo "Copying result xml and screenshots to ${ARTIFACT_DIR}"
# the file name must start with 'junit'
cp cypress/results/combined-report.xml ${ARTIFACT_DIR}/junit-kiali-cypress.xml
cp -r cypress/screenshots ${ARTIFACT_DIR}/ || true
cp -r /tmp/kiali/cypress/screenshots ${ARTIFACT_DIR}/ || true

# Preserve original test result files
original_results="${ARTIFACT_DIR}/original_results"
mkdir -p "${original_results}"

# Find xml files safely (null-delimited) and process them. This avoids word-splitting
# and is robust to filenames containing spaces/newlines.
while IFS= read -r -d '' result_file; do
    # Compute relative path under ARTIFACT_DIR to preserve structure in original_results
    rel_path="${result_file#$ARTIFACT_DIR/}"
    dest_path="${original_results}/${rel_path}"
    mkdir -p "$(dirname "$dest_path")"
    cp -- "$result_file" "$dest_path"

    # Map tests if needed for related use cases
    mapTestsForComponentReadiness "$result_file"

    # Send junit file to shared dir for Data Router Reporter step (use basename to avoid overwriting files with same name)
    cp -- "$result_file" "${SHARED_DIR}/$(basename "$result_file")"
done < <(find "${ARTIFACT_DIR}" -type f -iname "*.xml" -print0)

# cleaning demo apps
_output/kiali/hack/istio/install-testing-demos.sh -d true -c oc -in ${ISTIO_NAMESPACE}
