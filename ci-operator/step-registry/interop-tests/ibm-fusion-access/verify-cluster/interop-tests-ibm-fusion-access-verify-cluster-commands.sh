#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

eval "$(curl -fsSL \
    https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/\
libs/bash/ci-operator/interop/common/TestReport--JunitXml.sh
)"

LP_IO__TR__RESULTS_FILE="${ARTIFACT_DIR}/junit_verify_cluster_tests.xml"
LP_IO__TR__SUITE_NAME="Verify Cluster Tests"
LP_IO__TR__START_TIME="$(date +%s)"
trap 'TestReport--GenerateJunitXml' EXIT

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

testStart=$(date +%s)
testStatus="failed"
testMessage=""

if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null; then
  testStatus="passed"
else
  testMessage="Cluster ${STORAGE_SCALE_CLUSTER_NAME} not found in namespace ${STORAGE_SCALE_NAMESPACE}"
fi

TestReport--AddCase "test_cluster_exists" "${testStatus}" "$(($(date +%s) - testStart))" "${testMessage}"

testStart=$(date +%s)
testStatus="failed"
testMessage=""

oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
  -o jsonpath='{range .status.conditions[*]}    {.type}: {.status} - {.message}{"\n"}{end}'

successStatus=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")

if [[ "${successStatus}" == "True" ]]; then
  testStatus="passed"
else
  testMessage="Cluster Success condition is ${successStatus}, expected True"
fi

TestReport--AddCase "test_cluster_success_condition" "${testStatus}" "$(($(date +%s) - testStart))" "${testMessage}"

testStart=$(date +%s)
testStatus="failed"
testMessage=""

oc get pods -n "${STORAGE_SCALE_NAMESPACE}"

runningPods=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
totalPods=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)

if [[ "${runningPods}" -gt 0 ]] && [[ "${runningPods}" -eq "${totalPods}" ]]; then
  testStatus="passed"
elif [[ "${runningPods}" -gt 0 ]]; then
  testMessage="${runningPods} of ${totalPods} pods are running"
else
  testMessage="No running pods found in namespace ${STORAGE_SCALE_NAMESPACE}"
fi

TestReport--AddCase "test_cluster_pods_running" "${testStatus}" "$(($(date +%s) - testStart))" "${testMessage}"

true
