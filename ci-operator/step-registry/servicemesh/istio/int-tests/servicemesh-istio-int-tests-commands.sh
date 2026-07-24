#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# --- Configuration ---
readonly RETRY_SLEEP_INTERVAL=30

# --- Functions ---

# run_tests runs prow/integ-suite-ocp.sh directly from the step container.
# Images are pre-built and pushed to TEST_HUB by servicemesh-istio-images-build.
run_tests() {
  # Wait for kube-apiserver to be fully stable before running tests.
  ./prow/check-cluster-ready.sh

  if [ "${TEST_SUITE}" = "helm" ]; then
    export VARIANT=distroless
    export GCP_REGISTRIES=' '
  fi

  if [ "${TEST_SUITE}" = "ambient" ] && [ "${CONTROL_PLANE_SOURCE}" = "sail" ]; then
    export TRUSTED_ZTUNNEL_NAMESPACE=ztunnel
  fi

  # Set the test file name based on SMOKE_TEST
  export TEST_FILE_NAME="skip_tests_full.yaml"
  if [ "${SMOKE_TEST}" = "true" ]; then
    TEST_FILE_NAME="skip_tests_smoke.yaml"
  fi
  CONFIG_FILE="./prow/skip_tests/${TEST_FILE_NAME}"
  if [ ! -f "${CONFIG_FILE}" ]; then
    echo "Error: Config file ${CONFIG_FILE} not found in the repository under prow/skip_tests directory"
    echo "[debug]"
    pwd
    ls -la
    exit 1
  fi

  # Download the parse-test-config.sh script from the ci-utils repo
  curl -fO https://raw.githubusercontent.com/openshift-service-mesh/ci-utils/refs/heads/main/skip_tests/parse-test-config.sh
  chmod +x ./parse-test-config.sh

  # parse-test-config.sh expects midstream_sail vs midstream_helm (istio CP uses helm-style install in CI)
  case "${CONTROL_PLANE_SOURCE}" in
    sail)  PARSE_TEST_CONFIG_MIDSTREAM_VARIANT="midstream_sail" ;;
    istio) PARSE_TEST_CONFIG_MIDSTREAM_VARIANT="midstream_helm" ;;
    *)
      echo "Unsupported CONTROL_PLANE_SOURCE: ${CONTROL_PLANE_SOURCE} (expected istio or sail)" >&2
      exit 1
      ;;
  esac

  ./parse-test-config.sh "${CONFIG_FILE}" "${TEST_SUITE}" "${PARSE_TEST_CONFIG_MIDSTREAM_VARIANT}"
  # eval exports SKIP_PARSER_SKIP_TESTS and SKIP_PARSER_SKIP_SUBSUITES
  eval "$(./parse-test-config.sh "${CONFIG_FILE}" "${TEST_SUITE}" "${PARSE_TEST_CONFIG_MIDSTREAM_VARIANT}")"
  echo "[debug] ENVS after parser skip tests"
  echo "[debug] SKIP_PARSER_SKIP_TESTS: ${SKIP_PARSER_SKIP_TESTS}"
  echo "[debug] SKIP_PARSER_SKIP_SUBSUITES: ${SKIP_PARSER_SKIP_SUBSUITES}"

  # Derive the same unique image tag used by the images-build step
  if [ -n "${PULL_PULL_SHA:-}" ]; then
    export TAG="${PULL_PULL_SHA}"
  elif [ -n "${BUILD_ID:-}" ]; then
    export TAG="${BUILD_ID}"
  else
    echo "ERROR: Neither PULL_PULL_SHA nor BUILD_ID is set. Cannot derive image tag." >&2
    exit 1
  fi

  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  export SKIP_SETUP=true
  export BUILD_WITH_CONTAINER="0"

  prow/integ-suite-ocp.sh \
    "${TEST_SUITE}" "${SKIP_PARSER_SKIP_TESTS}" "${SKIP_PARSER_SKIP_SUBSUITES}"
}

# are_tests_done checks for /tmp/ISTIO_TESTS_DONE which integ-suite-ocp.sh creates
# at normal completion. Absence means the run was killed mid-flight.
are_tests_done() {
  echo "Checking if /tmp/ISTIO_TESTS_DONE exists"
  [ -f /tmp/ISTIO_TESTS_DONE ]
}

print_debug_info() {
  echo -e "\n"
  echo "################################################################"
  echo "     DEBUG INFO"
  echo "################################################################"
  echo "oc status:"
  oc status
  echo "All pods in ${MAISTRA_NAMESPACE}:"
  oc get pods -n "${MAISTRA_NAMESPACE}" || true
  echo "Events in ${MAISTRA_NAMESPACE}:"
  oc get events -n "${MAISTRA_NAMESPACE}" || true
  echo "All nodes:"
  oc get nodes -o wide
  oc describe nodes
  echo "Cluster operators:"
  oc get clusteroperators
}

clean_test_run() {
  echo "Cleaning previous test run"
  rm -f /tmp/ISTIO_TESTS_DONE

  if [ "${CONTROL_PLANE_SOURCE}" == "sail" ]; then
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

  # Restore any test-generated files in the workspace
  rm -f tests/integration/pilot/testdata/gateway-conformance-manifests.yaml
  git restore tests/integration/pilot/gateway_conformance_test.go || true

  oc delete namespace -l istio-testing

  echo "Sleeping 120s before starting new test run"
  sleep 120
}

echo "--- Running Istio int tests (attempt 1) ---"
set +o errexit
run_tests
TEST_RC=$?

if ! are_tests_done; then
  echo "WARNING: test run exited with ${TEST_RC} but /tmp/ISTIO_TESTS_DONE was not found."
  echo "This may indicate the test run was killed mid-flight (timeout, OOM, etc.)"
  print_debug_info

  echo "Retrying test execution in ${RETRY_SLEEP_INTERVAL} seconds..."
  sleep "${RETRY_SLEEP_INTERVAL}"

  clean_test_run

  echo "--- Running Istio int tests (attempt 2) ---"
  run_tests
  TEST_RC=$?

  if [ "${TEST_RC}" -ne 0 ] || ! are_tests_done; then
    echo "ERROR: Second attempt failed. Exit code: ${TEST_RC}, Marker file present: $(are_tests_done && echo "Yes" || echo "No")"
    print_debug_info
    exit 1
  else
    echo "SUCCESS: Second attempt passed successfully."
    exit 0
  fi
fi

set -o errexit

# Share artifacts with next job step which uploads results to report portal
echo "Copying artifacts to SHARED_DIR"
cp "${ARTIFACT_DIR}/junit/"* "${SHARED_DIR}"

echo "Istio int test execution completed with exit code: ${TEST_RC}"
exit "${TEST_RC}"
