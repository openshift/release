#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Create the IBM Storage Scale Cluster CR in the Storage Scale namespace, wait for readiness, and emit JUnit for ReportPortal when MAP_TESTS is enabled.
# Inputs: ARTIFACT_DIR, MAP_TESTS, FA__SCALE__NAMESPACE, FA__SCALE__CLUSTER_NAME, FA__SCALE__* resource requests, SHARED_DIR.
# Non-obvious: yq may be installed for ReportPortal mapping; cluster readiness uses jq against the Cluster status.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_create_cluster_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=''

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-ClusterCreationTests}"; (($#)) && shift

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
  <testsuite name="Create Cluster Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  MapTestsForComponentReadiness "${JUNIT_RESULTS_FILE:-${junitResultsFile}}"

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename "${junitResultsFile}")"
  fi

  if (( testsFailed > 0 )); then
    exit 1
  fi

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

typeset -i workerCount=0
workerCount=$(
  oc get nodes \
    -l node-role.kubernetes.io/worker= \
    -o jsonpath-as-json='{.items[*].metadata.name}' |
  jq 'length'
)

typeset -i td="${SECONDS}"
typeset ts='failed'
typeset msg=''
if {
  oc create -f - --dry-run=client -o json --save-config |
  jq \
    --arg ns "${FA__SCALE__NAMESPACE}" \
    --arg name "${FA__SCALE__CLUSTER_NAME}" \
    --arg clientCpu "${FA__SCALE__CLIENT_CPU}" \
    --arg clientMem "${FA__SCALE__CLIENT_MEMORY}" \
    --arg storageCpu "${FA__SCALE__STORAGE_CPU}" \
    --arg storageMem "${FA__SCALE__STORAGE_MEMORY}" \
    --argjson quorum "$(( workerCount >= 3 ? 1 : 0 ))" \
    '
      .metadata.name = $name |
      .metadata.namespace = $ns |
      .spec.daemon.roles[0].resources = { cpu: $clientCpu, memory: $clientMem } |
      .spec.daemon.roles[1].resources = { cpu: $storageCpu, memory: $storageMem } |
      if $quorum == 0 then del(.spec.quorum) else . end
    ' |
  yq -p json -o yaml eval .
} 0<<'SKELETON' | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata: {}
spec:
  license:
    accept: true
    license: data-management
  quorum:
    autoAssign: true
  pmcollector:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
  daemon:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
    nsdDevicesConfig:
      localDevicePaths:
      - devicePath: /dev/disk/by-id/*
        deviceType: generic
    clusterProfile:
      controlSetxattrImmutableSELinux: "yes"
      enforceFilesetQuotaOnRoot: "yes"
      ignorePrefetchLUNCount: "yes"
      initPrefetchBuffers: "128"
      maxblocksize: "16M"
      prefetchPct: "25"
      prefetchTimeout: "30"
    roles:
    - name: client
      resources: {}
    - name: storage
      resources: {}
SKELETON
then
  ts='passed'
else
  oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" -o yaml --ignore-not-found
  msg='Failed to create Cluster resource via oc apply'
fi
td=$((SECONDS - td))
AddTestResult "test_cluster_apply" "${ts}" "${td}" "${msg}"

td="${SECONDS}"
ts='failed'
msg=''
if oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
  cluster/"${FA__SCALE__CLUSTER_NAME}" \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout="${FA__SCALE__CLUSTER_READY_TIMEOUT}"; then
  ts='passed'
else
  oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" -o yaml --ignore-not-found
  msg='Cluster did not report Success within timeout'
fi
td=$((SECONDS - td))
AddTestResult "test_cluster_ready" "${ts}" "${td}" "${msg}"

true
