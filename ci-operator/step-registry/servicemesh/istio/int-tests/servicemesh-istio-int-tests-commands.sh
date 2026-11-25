#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# run_tests runs prow/integ-suite-ocp.sh directly from the step container.
# Images are pre-built and pushed to TEST_HUB by servicemesh-istio-images-build.
run_tests() {
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"

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

  # Run once; capture export statements to a temp file and source them
  _parse_config_tmp=$(mktemp)
  ./parse-test-config.sh "${CONFIG_FILE}" "${TEST_SUITE}" "${PARSE_TEST_CONFIG_MIDSTREAM_VARIANT}" > "${_parse_config_tmp}"
  # shellcheck source=/dev/null
  source "${_parse_config_tmp}"
  rm -f "${_parse_config_tmp}"
  echo "[debug] ENVS after parser skip tests"
  echo "[debug] SKIP_PARSER_SKIP_TESTS: ${SKIP_PARSER_SKIP_TESTS}"
  echo "[debug] SKIP_PARSER_SKIP_SUBSUITES: ${SKIP_PARSER_SKIP_SUBSUITES}"

  # Load the image tag and hub written by the images-build step.
  # prow/integ-suite-ocp.sh reads HUB and TAG (not TEST_HUB) to locate images.
  export TAG
  TAG=$(cat "${SHARED_DIR}/istio-image-tag")
  export HUB="${TEST_HUB}"

  export SKIP_SETUP=true
  export BUILD_WITH_CONTAINER="0"
  # OpenShift sets NAMESPACE to the CI step container's own namespace (ci-op-*).
  # Force istio-system so the sail-operator-setup.sh converter uses the right namespace
  # for the Istio CR and the istiod wait; without this the CR gets spec.namespace=ci-op-*
  # and the sail operator has no RBAC to create resources there.
  export NAMESPACE=istio-system

  prow/integ-suite-ocp.sh \
    "${TEST_SUITE}" "${SKIP_PARSER_SKIP_TESTS}" "${SKIP_PARSER_SKIP_SUBSUITES}"
}

echo "--- Running Istio int tests ---"
set +o errexit
run_tests
TEST_RC=$?
set -o errexit

# Share artifacts with next job step which uploads results to report portal
echo "Copying artifacts to SHARED_DIR"
cp "${ARTIFACT_DIR}/junit/"* "${SHARED_DIR}"

echo "Istio int test execution completed with exit code: ${TEST_RC}"
exit "${TEST_RC}"
