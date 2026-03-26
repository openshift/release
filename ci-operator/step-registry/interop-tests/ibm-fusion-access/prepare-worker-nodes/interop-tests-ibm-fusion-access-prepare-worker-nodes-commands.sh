#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Prepare per-worker directories for IBM Storage Scale on nodes, record JUnit per node, and map tests for ReportPortal when MAP_TESTS is enabled.
# Inputs: MAP_TESTS, REPORTPORTAL_CMP (step ref env); ARTIFACT_DIR, SHARED_DIR (CI).
# Non-obvious: oc debug runs a nested bash script with errexit and inherit_errexit to create host paths under chroot.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_prepare_worker_nodes_tests.xml"
typeset testStartTime=0
testStartTime=$(date +%s)
typeset testsTotal=0
typeset testsFailed=0
typeset testCases=''

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-PrepareWorkerNodesTests}"; (($#)) && shift

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
    typeset yqPath=''
    if yqPath="$(type -P yq)"; then
        true
    fi
    if [[ -z "${yqPath}" ]]; then
        mkdir -p /tmp/bin
        export PATH="${PATH}:/tmp/bin/"
        typeset cpuArch=''
        cpuArch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${cpuArch}" \
            -o /tmp/bin/yq
        chmod +x /tmp/bin/yq
    fi
    true
}

function MapTestsForComponentReadiness () {
    [[ "${MAP_TESTS}" != "true" ]] && return

    typeset resultsFile="${1}"
    if [[ -f "${resultsFile}" ]]; then
        InstallYQIfNotExists
        yq eval -px -ox -iI0 '.testsuites.testsuite.+@name=env(REPORTPORTAL_CMP)' "${resultsFile}"
    fi
    true
}

function GenerateJunitXml () {
  typeset totalDuration=0
  totalDuration=$(($(date +%s) - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Prepare Worker Nodes Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  MapTestsForComponentReadiness "${junitResultsFile}"

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename "${junitResultsFile}")"
  fi

  if [[ "${testsFailed}" -gt 0 ]]; then
    exit 1
  fi

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

typeset nodesJson=''
nodesJson="$(oc get nodes -l node-role.kubernetes.io/worker= -o json)"
typeset -i workerCount=0
workerCount="$(printf '%s' "${nodesJson}" | jq '.items | length')"
if [[ "${workerCount}" -eq 0 ]]; then
  oc get nodes
  exit 1
fi

typeset -a targetDirs=(
  "/var/lib/firmware"
  "/var/mmfs/etc"
  "/var/mmfs/tmp/traces"
  "/var/mmfs/pmcollector"
)

typeset nodeName=''
while IFS= read -r nodeName; do
  typeset testStart=0
  testStart=$(date +%s)
  typeset testStatus='failed'
  typeset testMessage=''
  typeset -a failedDirs=()

  typeset mkdirOutput=''
  if mkdirOutput="$(oc debug -n default node/"${nodeName}" -- chroot /host \
    bash -c 'set -euo pipefail; shopt -s inherit_errexit
for d in /var/lib/firmware /var/mmfs/etc /var/mmfs/tmp/traces /var/mmfs/pmcollector; do
      mkdir -p "${d}" && test -d "${d}" && printf "ok:%s\n" "${d}" || printf "fail:%s\n" "${d}"
    done
true')"; then
    true
  else
    mkdirOutput=''
  fi

  typeset targetDir=''
  for targetDir in "${targetDirs[@]}"; do
    if [[ "${mkdirOutput}" != *"ok:${targetDir}"* ]]; then
      failedDirs+=("${targetDir}")
    fi
  done

  if [[ "${#failedDirs[@]}" -eq 0 ]]; then
    testStatus='passed'
  else
    testMessage="Failed to create directories on node ${nodeName}: ${failedDirs[*]}"
  fi

  typeset testDuration=0
  testDuration=$(($(date +%s) - testStart))
  typeset sanitizedNode=''
  sanitizedNode="$(printf '%s' "${nodeName}" | tr '.-' '__')"
  AddTestResult "test_prepare_node_${sanitizedNode}" "${testStatus}" "${testDuration}" "${testMessage}"
done < <(printf '%s' "${nodesJson}" | jq -r '.items[].metadata.name')

true
