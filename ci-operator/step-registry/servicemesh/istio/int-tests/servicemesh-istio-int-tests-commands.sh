#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# --- Configuration ---
readonly RETRY_SLEEP_INTERVAL=30
readonly POLL_INTERVAL=30
# Markers written inside the builder pod by the detached wrapper.
readonly DONE_MARKER=/tmp/ISTIO_TESTS_DONE
readonly RC_MARKER=/tmp/TESTS_RC
readonly TEST_LOG=/tmp/test-run.log
readonly RUNNER_SCRIPT=/tmp/run-istio-int-tests.sh

# --- Functions ---

pod_exec() {
  oc exec -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -- "$@"
}

# Clear previous run markers/logs so a stale done file cannot short-circuit polling.
clear_test_markers() {
  pod_exec sh -c "rm -f '${DONE_MARKER}' '${RC_MARKER}' '${TEST_LOG}' '${RUNNER_SCRIPT}'" || true
}

# are_tests_done requires both the suite/wrapper done marker and an RC file.
are_tests_done() {
  echo "Checking for ${DONE_MARKER} and ${RC_MARKER}"
  pod_exec sh -c "test -f '${DONE_MARKER}' && test -f '${RC_MARKER}'"
}

read_test_rc() {
  pod_exec sh -c "tr -d '[:space:]' < '${RC_MARKER}'"
}

# Dump the complete detached suite log into the Prow build log and ARTIFACT_DIR
# once the run finishes (success or failure). Sleep-pod PID1 has no useful oc logs.
dump_full_test_log() {
  echo "================================================================"
  echo "BEGIN full detached test log (${TEST_LOG})"
  echo "================================================================"
  if pod_exec sh -c "test -f '${TEST_LOG}'"; then
    pod_exec cat "${TEST_LOG}" || true
    mkdir -p "${ARTIFACT_DIR}"
    oc cp "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:${TEST_LOG}" "${ARTIFACT_DIR}/detached-test-run.log" || true
    echo "Full detached test log also saved to ${ARTIFACT_DIR}/detached-test-run.log"
  else
    echo "WARNING: ${TEST_LOG} not found in ${MAISTRA_SC_POD}; nothing to dump"
  fi
  echo "================================================================"
  echo "END full detached test log"
  echo "================================================================"
}

# wait_for_tests polls with short oc exec until done+RC exist. Brief API blips are retried.
wait_for_tests() {
  echo "Polling for detached test completion (${DONE_MARKER} + ${RC_MARKER})..."
  local poll_failures=0
  local max_consecutive_poll_failures=20

  while true; do
    if are_tests_done; then
      echo "Detached tests finished (markers present)."
      return 0
    fi

    if pod_exec sh -c "true" >/dev/null 2>&1; then
      poll_failures=0
      echo "Detached tests still running; waiting for ${DONE_MARKER} + ${RC_MARKER}..."
    else
      poll_failures=$((poll_failures + 1))
      echo "WARNING: short oc exec failed while polling (${poll_failures}/${max_consecutive_poll_failures}). Will retry."
      if [ "${poll_failures}" -ge "${max_consecutive_poll_failures}" ]; then
        echo "ERROR: too many consecutive poll failures talking to ${MAISTRA_SC_POD}" >&2
        return 1
      fi
    fi

    sleep "${POLL_INTERVAL}"
  done
}

collect_artifacts() {
  echo "Copying artifacts from test pod"
  oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}" || true

  echo "Copying artifacts to SHARED_DIR"
  # junit dir may be missing on hard failures; do not fail the step solely on copy
  if [ -d "${ARTIFACT_DIR}/junit" ]; then
    cp "${ARTIFACT_DIR}/junit/"* "${SHARED_DIR}" || true
  else
    echo "WARNING: ${ARTIFACT_DIR}/junit not found; nothing to share with ReportPortal"
  fi
}

# start_detached_tests writes a runner script into the pod and nohup-starts it so the
# suite is not tied to a long-lived oc rsh WebSocket (close 1006 / K8s #130885).
start_detached_tests() {
  clear_test_markers

  local local_runner
  local_runner="$(mktemp)"
  # Host-side expansion for CI env; escape \$ for values evaluated inside the pod.
  cat > "${local_runner}" <<EOF
#!/bin/bash
set +e
export KUBECONFIG=/work/ci-kubeconfig
export BUILD_WITH_CONTAINER="0"
export ENABLE_OVERLAY2_STORAGE_DRIVER=true
export DOCKER_INSECURE_REGISTRIES="default-route-openshift-image-registry.\$(oc get routes -A -o jsonpath='{.items[0].spec.host}' | awk -F. '{print substr(\$0, index(\$0,\$2))}')"
export ARTIFACT_DIR="${ARTIFACT_DIR}"
export CONTROL_PLANE_SOURCE="${CONTROL_PLANE_SOURCE}"
export INSTALL_SAIL_OPERATOR="${INSTALL_SAIL_OPERATOR}"
export AMBIENT="${AMBIENT}"
${AMBIENT_ENV_VAR_EXPORT:-}
${HELM_ENV_VAR_EXPORT:-}
oc version
cd /work
entrypoint prow/integ-suite-ocp.sh '${TEST_SUITE}' '${SKIP_PARSER_SKIP_TESTS}' '${SKIP_PARSER_SKIP_SUBSUITES}'
rc=\$?
echo "\$rc" > ${RC_MARKER}
# Ensure a done marker even if the suite did not write one (wrapper owns completion).
touch ${DONE_MARKER}
exit "\$rc"
EOF

  echo "Copying detached runner into ${MAISTRA_SC_POD}:${RUNNER_SCRIPT}"
  oc cp "${local_runner}" "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:${RUNNER_SCRIPT}"
  rm -f "${local_runner}"
  pod_exec chmod +x "${RUNNER_SCRIPT}"

  echo "Starting detached Istio integ suite in ${MAISTRA_SC_POD}..."
  pod_exec sh -c "nohup '${RUNNER_SCRIPT}' > '${TEST_LOG}' 2>&1 < /dev/null & echo \"Started PID \$!\""
}

# run_tests prepares skip lists, starts the detached suite, waits for markers, returns suite RC.
run_tests() {
  # Wait for kube-apiserver to be stable before opening short exec sessions.
  ./prow/check-cluster-ready.sh

  HELM_ENV_VAR_EXPORT=""
  AMBIENT_ENV_VAR_EXPORT=""
  if [ "${TEST_SUITE}" = "helm" ]
  then
    HELM_ENV_VAR_EXPORT="export VARIANT=distroless;export GCP_REGISTRIES=' '"
  fi

  if [ "${TEST_SUITE}" = "ambient" ] && [ "${CONTROL_PLANE_SOURCE}" = "sail" ]
  then
    AMBIENT_ENV_VAR_EXPORT="export TRUSTED_ZTUNNEL_NAMESPACE=ztunnel"
  fi

  # set the test file name based on the SMOKE_TEST environment variable
  export TEST_FILE_NAME="skip_tests_full.yaml"
  if [ "${SMOKE_TEST}" = "true" ]; then
      TEST_FILE_NAME="skip_tests_smoke.yaml"
  fi
  # check whether the config file exists in the repo under prow/skip_tests directory
  CONFIG_FILE="./prow/skip_tests/${TEST_FILE_NAME}"
  if [ ! -f "${CONFIG_FILE}" ]; then
      echo "Error: Config file ${CONFIG_FILE} not found in the repository under prow/skip_tests directory"
      echo "[debug]"
      pwd
      ls -la
      exit 1
  fi

  # download the parse-test-config.sh script from the ci-utils repo
  curl -fO https://raw.githubusercontent.com/openshift-service-mesh/ci-utils/refs/heads/main/skip_tests/parse-test-config.sh
  chmod +x ./parse-test-config.sh

  # parse-test-config.sh expects midstream_sail vs midstream_helm (istio CP uses helm-style install in CI)
  case "${CONTROL_PLANE_SOURCE}" in
    sail)
      PARSE_TEST_CONFIG_MIDSTREAM_VARIANT="midstream_sail"
      ;;
    istio)
      PARSE_TEST_CONFIG_MIDSTREAM_VARIANT="midstream_helm"
      ;;
    *)
      echo "Unsupported CONTROL_PLANE_SOURCE: ${CONTROL_PLANE_SOURCE} (expected istio or sail)" >&2
      exit 1
      ;;
  esac

  ./parse-test-config.sh "${CONFIG_FILE}" "${TEST_SUITE}" "${PARSE_TEST_CONFIG_MIDSTREAM_VARIANT}"
  # it will eval SKIP_PARSER_SKIP_TESTS and SKIP_PARSER_SKIP_SUBSUITES ENV variables which will be used in the prow/integ-suite-ocp.sh
  eval "$(./parse-test-config.sh "${CONFIG_FILE}" "${TEST_SUITE}" "${PARSE_TEST_CONFIG_MIDSTREAM_VARIANT}")"
  echo "[debug] ENVS after parser skip tests"
  echo "[debug] SKIP_PARSER_SKIP_TESTS: ${SKIP_PARSER_SKIP_TESTS}"
  echo "[debug] SKIP_PARSER_SKIP_SUBSUITES: ${SKIP_PARSER_SKIP_SUBSUITES}"

  start_detached_tests
  if ! wait_for_tests; then
    echo "ERROR: failed while waiting for detached Istio integ tests" >&2
    dump_full_test_log
    return 1
  fi

  dump_full_test_log

  local rc
  rc="$(read_test_rc)"
  echo "Detached suite exit code: ${rc}"
  return "${rc}"
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
  echo "Executing dummy cmd via oc exec on ${MAISTRA_SC_POD}"
  pod_exec sh -c "echo 'oc exec works'" || true
  dump_full_test_log
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
    oc delete istiocni --all -n istio-cni --wait=true --timeout=120s || true
    oc delete ztunnel --all -n ztunnel --wait=true --timeout=120s || true
    oc delete istio --all -n istio-system --wait=true --timeout=120s || true
    oc delete namespace istio-system istio-cni ztunnel || true

    rm -rf sail-operator
  else
    curl -sL https://istio.io/downloadIstioctl | sh -
    export PATH=$HOME/.istioctl/bin:$PATH
    istioctl uninstall --purge -y || true
    oc delete namespace istio-system || true
  fi

  pod_exec sh -c '
      cd /work
      rm -f tests/integration/pilot/testdata/gateway-conformance-manifests.yaml
      git restore tests/integration/pilot/gateway_conformance_test.go || true
      ' || true
  oc delete namespace -l istio-testing || true

  clear_test_markers

  echo "Sleeping 120s before starting new test run"
  # TODO: it does not help to wait for cluster operators to be stable because they are already stable but sometimes there are still weird EOF or 500 errors
  # keeping the sleep here just to be sure
  sleep 120
}

echo "--- Running Istio int tests (attempt 1) ---"
set +o errexit
run_tests
TEST_RC=$?

if ! are_tests_done; then
  echo "WARNING: Detached test run ended without ${DONE_MARKER}/${RC_MARKER} (exit ${TEST_RC})."
  echo "This may indicate the builder pod/process died mid-run."
  print_debug_info

  echo "Retrying test execution in ${RETRY_SLEEP_INTERVAL} seconds..."
  sleep "${RETRY_SLEEP_INTERVAL}"

  # Ensure clean_test_run wipes any partial state or stale files
  clean_test_run

  echo "--- Running Istio int tests (attempt 2) ---"
  run_tests
  TEST_RC=$?

  if [ "${TEST_RC}" -ne 0 ] || ! are_tests_done; then
    echo "ERROR: Second attempt failed. Exit code: ${TEST_RC}, Markers present: $(are_tests_done && echo "Yes" || echo "No")"
    print_debug_info
    collect_artifacts
    exit 1
  fi
  echo "SUCCESS: Second attempt passed successfully."
fi

set -o errexit
collect_artifacts

echo "Istio int test execution completed with exit code: ${TEST_RC}"
exit "${TEST_RC}"
