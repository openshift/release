#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Verify the Storage Scale cluster CR, operator pods, and related conditions; emit JUnit and optional ReportPortal mapping.
# Inputs: ARTIFACT_DIR, MAP_TESTS, FA__SCALE__CLUSTER_NAME, FA__SCALE__NAMESPACE, SHARED_DIR; yq when MAP_TESTS is true.
# Non-obvious: Dumps cluster and pod status via jq for diagnostics on failure.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_verify_cluster_tests.xml"
typeset -i testStartTime=0
testStartTime="$(date +%s)"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=""

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-VerifyClusterTests}"; (($#)) && shift
  
  ((++testsTotal))
  
  if [[ "${testStatus}" == "passed" ]]; then
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\"/>"
  else
    ((++testsFailed))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${testMessage}</failure>
    </testcase>"
  fi

  true
}

function InstallYQIfNotExists () {
  if ! command -v yq >/dev/null; then
    typeset arch=''
    arch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
    mkdir -p /tmp/bin
    export PATH="${PATH}:/tmp/bin/"
    curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
      -o /tmp/bin/yq && chmod +x /tmp/bin/yq
  fi

  true
}

function MapTestsForComponentReadiness () {
  [[ "${MAP_TESTS:-false}" != "true" ]] && return

  typeset resultsFile="${1:-}"; (($#)) && shift
  if [[ -n "${resultsFile}" ]] && [[ -f "${resultsFile}" ]]; then
    InstallYQIfNotExists
    export REPORTPORTAL_CMP="${REPORTPORTAL_CMP:-}"
    yq eval -px -ox -iI0 '.testsuites.testsuite.+@name=env(REPORTPORTAL_CMP)' "${resultsFile}"
  fi

  true
}

function GenerateJunitXml () {
  typeset -i totalDuration=0
  totalDuration=$(($(date +%s) - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Verify Cluster Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  MapTestsForComponentReadiness "${JUNIT_RESULTS_FILE:-${junitResultsFile}}"

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename "${junitResultsFile}")"
  fi

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

typeset -i testStart=0
testStart="$(date +%s)"
typeset testStatus="failed"
typeset testMessage=""
typeset -i testDuration=0

typeset clusterJson=''
if clusterJson="$(oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" -o json)"; then
  testStatus="passed"
else
  testMessage="Cluster ${FA__SCALE__CLUSTER_NAME} not found in namespace ${FA__SCALE__NAMESPACE}"
fi

testDuration=$(($(date +%s) - testStart))
AddTestResult "test_cluster_exists" "${testStatus}" "${testDuration}" "${testMessage}"

testStart="$(date +%s)"
testStatus="failed"
testMessage=""

typeset successStatus=''
if [[ -n "${clusterJson}" ]]; then
  printf '%s' "${clusterJson}" | jq -r '.status.conditions[]? | "    \(.type): \(.status) - \(.message)"'
  successStatus="$(printf '%s' "${clusterJson}" | jq -r '.status.conditions[]? | select(.type=="Success") | .status // empty')"
fi

if [[ "${successStatus}" == "True" ]]; then
  testStatus="passed"
elif [[ -z "${clusterJson}" ]]; then
  testMessage="Cluster not found, cannot verify Success condition"
else
  testMessage="Cluster Success condition is ${successStatus}, expected True"
fi

testDuration=$(($(date +%s) - testStart))
AddTestResult "test_cluster_success_condition" "${testStatus}" "${testDuration}" "${testMessage}"

testStart="$(date +%s)"
testStatus="failed"
testMessage=""

typeset podsJson=''
if podsJson="$(oc get pods -n "${FA__SCALE__NAMESPACE}" -o json)"; then
  printf '%s' "${podsJson}" | jq -r '.items[]? | "\(.metadata.name) \(.status.phase)"'
  typeset -i runningPods=0
  runningPods=$(printf '%s' "${podsJson}" | jq '[.items[]? | select(.status.phase=="Running")] | length')
  typeset -i totalPods=0
  totalPods=$(printf '%s' "${podsJson}" | jq '.items | length')

  if [[ "${runningPods}" -gt 0 ]] && [[ "${runningPods}" -eq "${totalPods}" ]]; then
    testStatus="passed"
  elif [[ "${runningPods}" -gt 0 ]]; then
    testMessage="${runningPods} of ${totalPods} pods are running"
  else
    testMessage="No running pods found in namespace ${FA__SCALE__NAMESPACE}"
  fi
else
  testMessage="Failed to list pods in namespace ${FA__SCALE__NAMESPACE}"
fi

testDuration=$(($(date +%s) - testStart))
AddTestResult "test_cluster_pods_running" "${testStatus}" "${testDuration}" "${testMessage}"

true
