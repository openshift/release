#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# --- Configuration ---
readonly RETRY_SLEEP_INTERVAL=30

# --- Functions ---

# run_tests executes the main test command inside the test pod
run_tests() {
  if [ "${TEST_SUITE}" = "helm" ]
  then
    HELM_ENV_VAR_EXPORT="export VARIANT=distroless;export GCP_REGISTRIES=' '"
  fi

  if [ "${TEST_SUITE}" = "ambient" ] && [ "${CONTROL_PLANE_SOURCE}" = "sail" ]
  then
    AMBIENT_ENV_VAR_EXPORT="export TRUSTED_ZTUNNEL_NAMESPACE=ztunnel"
  fi

  oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
    sh -c "
    export KUBECONFIG=/work/ci-kubeconfig
    export BUILD_WITH_CONTAINER=\"0\"
    export ENABLE_OVERLAY2_STORAGE_DRIVER=true
    export DOCKER_INSECURE_REGISTRIES=\"default-route-openshift-image-registry.\$(oc get routes -A -o jsonpath='{.items[0].spec.host}' | awk -F. '{print substr(\$0, index(\$0,\$2))}')\"
    export ARTIFACT_DIR=\"${ARTIFACT_DIR}\"
    export CONTROL_PLANE_SOURCE=\"${CONTROL_PLANE_SOURCE}\"
    export INSTALL_SAIL_OPERATOR=\"${INSTALL_SAIL_OPERATOR}\"
    export AMBIENT=\"${AMBIENT}\"
    ${AMBIENT_ENV_VAR_EXPORT:-}
    ${HELM_ENV_VAR_EXPORT:-}
    oc version
    cd /work
    entrypoint \
    prow/integ-suite-ocp.sh \
    ${TEST_SUITE} '${SKIPPED_TESTS}' '${SKIPPED_SUITES}'"
}

# check if /tmp/ISTIO_TESTS_DONE file exists which marks whole test run as done
are_tests_done() {
  echo "Checking if /tmp/ISTIO_TESTS_DONE file exists"
  oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
    sh -c "if [ ! -f /tmp/ISTIO_TESTS_DONE ]; then echo '/tmp/ISTIO_TESTS_DONE not found!';exit 1;fi"
}

print_debug_info() {
  echo -e "\n"
  echo "################################################################"
  echo "     DEBUG INFO"
  echo "################################################################"
  echo "oc status:"
  oc status
  echo "All pods in ${MAISTRA_NAMESPACE}:"
  oc get pods -n ${MAISTRA_NAMESPACE} || true
  echo "Events in ${MAISTRA_NAMESPACE}:"
  oc get events -n ${MAISTRA_NAMESPACE} || true
  echo "oc describe pod ${MAISTRA_SC_POD}:"
  oc describe pod -n ${MAISTRA_NAMESPACE} ${MAISTRA_SC_POD} || true
  echo "Executing dummy cmd via rsh on ${MAISTRA_SC_POD}"
  oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" sh -c "echo 'rsh works'" || true
  echo "All nodes:"
  oc get nodes -o wide
  oc describe nodes
  echo "Cluster operators:"
  oc get clusteroperators
}

clean_test_run() {
  echo "Cleaning previous test run"
  if [ "${CONTROL_PLANE_SOURCE}" == "sail" ]
  then
    oc delete istiocni --all -n istio-cni --wait=true --timeout=120s
    oc delete ztunnel --all -n ztunnel --wait=true --timeout=120s
    oc delete istio --all -n istio-system --wait=true --timeout=120s
    oc delete namespace istio-system istio-cni ztunnel
  else
    curl -sL https://istio.io/downloadIstioctl | sh -
    export PATH=$HOME/.istioctl/bin:$PATH
    istioctl uninstall --purge -y
    oc delete namespace istio-system
  fi

  oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
    sh -c '
      cd /work
      rm -f tests/integration/pilot/testdata/gateway-conformance-manifests.yaml
      git restore tests/integration/pilot/gateway_conformance_test.go || true
      '
  oc delete namespace -l istio-testing

  echo "Sleeping 120s before starting new test run"
  # TODO: it does not help to wait for cluster operators to be stable because they are already stable but sometimes there are still weird EOF or 500 errors
  # keeping the sleep here just to be sure
  sleep 120
}

echo "--- Running Istio int tests (attempt 1) ---"
set +o errexit
run_tests
TEST_RC=$?

if [ "${TEST_RC}" -eq 0 ] && ! are_tests_done; then
  echo "WARNING: oc rsh exited with 0 but /tmp/ISTIO_TESTS_DONE file was not found. This may indicate a known bug K8s #130885"
  print_debug_info
  echo "Retrying test execution in ${RETRY_SLEEP_INTERVAL} seconds..."
  sleep "${RETRY_SLEEP_INTERVAL}"
  clean_test_run
  echo "--- Running Istio int tests (attempt 2) ---"
  run_tests
  TEST_RC=$?
  if [ "${TEST_RC}" -eq 0 ] && ! are_tests_done; then
    echo "WARNING: oc rsh exited with 0 but /tmp/ISTIO_TESTS_DONE file was not found. This may indicate a known bug K8s #130885"
    print_debug_info
    echo "Second attempt was not succesful"
  fi
fi

set -o errexit
echo "Copying artifacts from test pod"
oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"

# share artifacts with next job step which is uploading results to report portal
echo "Copying artifacts to SHARED_DIR"
cp "${ARTIFACT_DIR}/junit/"* "${SHARED_DIR}"

echo "Istio int test execution completed with exit code: ${TEST_RC}"
exit "${TEST_RC}"
