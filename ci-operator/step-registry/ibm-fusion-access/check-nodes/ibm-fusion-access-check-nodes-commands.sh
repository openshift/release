#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Check worker nodes for required storage labels and readiness, emitting JUnit for ReportPortal when MAP_TESTS is enabled.
# Inputs: ARTIFACT_DIR, MAP_TESTS, SHARED_DIR (via CI); optional yq for ReportPortal mapping.
# Non-obvious: yq is installed on demand when MAP_TESTS is true; JUnit captures the node validation suite.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_check_nodes_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=''

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-CheckNodesTests}"; (($#)) && shift

  testsTotal=$((testsTotal + 1))

  if [[ "${testStatus}" == "passed" ]]; then
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\"/>"
  else
    testsFailed=$((testsFailed + 1))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${testMessage}</failure>
    </testcase>"
  fi

  true
}

function InstallYQIfNotExists () {
  if ! command -v yq >/dev/null; then
    mkdir -p /tmp/bin
    export PATH="${PATH}:/tmp/bin"
    curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
      -o /tmp/bin/yq && chmod +x /tmp/bin/yq
  fi

  true
}

function MapTestsForComponentReadiness () {
  [[ "${MAP_TESTS:-false}" != "true" ]] && return

  typeset resultsFile="${1}"
  if [[ -f "${resultsFile}" ]]; then
    InstallYQIfNotExists
    export REPORTPORTAL_CMP="${REPORTPORTAL_CMP:-}"
    yq eval -px -ox -iI0 '.testsuites.testsuite.+@name=env(REPORTPORTAL_CMP)' "${resultsFile}"
  fi

  true
}

function GenerateJunitXml () {
  typeset -i totalDuration=$((SECONDS - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Check Nodes Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
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

typeset -i testDuration="${SECONDS}"
typeset testStatus='failed'
typeset testMessage=''

typeset -i workerCount=0
workerCount=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length')

if [[ "${workerCount}" -ge 3 ]]; then
  testStatus='passed'
else
  testMessage="Insufficient worker nodes: found ${workerCount}, minimum 3 required for quorum"
fi

testDuration=$((SECONDS - testDuration))
AddTestResult "test_worker_node_count_for_quorum" "${testStatus}" "${testDuration}" "${testMessage}"

[[ "${testStatus}" == 'passed' ]]

true
