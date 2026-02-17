#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__CLUSTER_NAME="${FA__SCALE__CLUSTER_NAME:-ibm-spectrum-scale}"
FA__SCALE__CLIENT_CPU="${FA__SCALE__CLIENT_CPU:-2}"
FA__SCALE__CLIENT_MEMORY="${FA__SCALE__CLIENT_MEMORY:-4Gi}"
FA__SCALE__STORAGE_CPU="${FA__SCALE__STORAGE_CPU:-2}"
FA__SCALE__STORAGE_MEMORY="${FA__SCALE__STORAGE_MEMORY:-8Gi}"

# JUnit XML test results configuration
junitResultsFile="${ARTIFACT_DIR}/junit_create_cluster_tests.xml"
testStartTime=$(date +%s)
testsTotal=0
testsFailed=0
testsPassed=0
testCases=""

# Function to add test result to JUnit XML
AddTestResult() {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift  # "passed" or "failed"
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-ClusterCreationTests}"; (($#)) && shift
  
  testsTotal=$((testsTotal + 1))
  
  if [[ "$testStatus" == "passed" ]]; then
    testsPassed=$((testsPassed + 1))
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

# Function to generate JUnit XML report
GenerateJunitXml() {
  typeset totalDuration=$(($(date +%s) - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Create Cluster Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results Summary: Total=${testsTotal} Passed=${testsPassed} Failed=${testsFailed} Duration=${totalDuration}s"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename ${junitResultsFile})"
    : 'Results copied to SHARED_DIR'
  fi
  
  # Exit with failure if any tests failed
  if [[ ${testsFailed} -gt 0 ]]; then
    : "Test suite failed: ${testsFailed} test(s) failed"
    exit 1
  fi

  true
}

# Trap to ensure JUnit XML is generated even on failure
trap GenerateJunitXml EXIT

: 'Creating IBM Storage Scale Cluster...'

# Test 1: Check if cluster already exists (idempotent)
: 'Test 1: Check cluster pre-existence...'
test1Start=$(date +%s)
test1Status="passed"
test1Message=""

if oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  : 'Cluster already exists (idempotent)'
  clusterExists=true
else
  : 'Cluster does not exist, will create'
  clusterExists=false
fi

test1Duration=$(($(date +%s) - test1Start))
AddTestResult "test_cluster_idempotency_check" "$test1Status" "$test1Duration" "$test1Message"

# Test 2: Create Cluster resource (without hardcoded device paths)
if [[ "$clusterExists" == "false" ]]; then
  : 'Test 2: Create Cluster resource...'
  test2Start=$(date +%s)
  test2Status="failed"
  test2Message=""
  
  # Determine quorum configuration based on worker count
  workerCount=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
  
  if [[ $workerCount -ge 3 ]]; then
    quorumConfig="quorum:
    autoAssign: true"
  else
    : "Only $workerCount worker nodes (3 recommended for quorum)"
    quorumConfig=""
  fi
  
  # Create cluster for FusionAccess shared SAN configuration
  # Auto-discovery is preferred for shared LUNs on AWS (per product expert)
  # FusionAccess operator discovers shared devices via storageDeviceDiscovery
  if cat <<EOF | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata:
  name: ${FA__SCALE__CLUSTER_NAME}
  namespace: ${FA__SCALE__NAMESPACE}
spec:
  license:
    accept: true
    license: data-management
  pmcollector:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
  daemon:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
    nsdDevicesConfig:
      bypassDiscovery: false
    clusterProfile:
      cloudEnv: general
      controlSetxattrImmutableSELinux: "yes"
      enforceFilesetQuotaOnRoot: "yes"
      ignorePrefetchLUNCount: "yes"
      ignoreReplicaSpaceOnStat: "yes"
      ignoreReplicationForQuota: "yes"
      ignoreReplicationOnStatfs: "yes"
      initPrefetchBuffers: "128"
      maxblocksize: 16M
      prefetchPct: "25"
      prefetchTimeout: "30"
      readReplicaPolicy: local
      traceGenSubDir: /var/mmfs/tmp/traces
      tscCmdPortRange: 60000-61000
    update:
      paused: false
    roles:
    - name: client
      resources:
        cpu: "${FA__SCALE__CLIENT_CPU}"
        memory: ${FA__SCALE__CLIENT_MEMORY}
    - name: storage
      resources:
        cpu: "${FA__SCALE__STORAGE_CPU}"
        memory: ${FA__SCALE__STORAGE_MEMORY}
  gui:
    enableSessionIPCheck: true
  ${quorumConfig}
EOF
  then
    : 'Cluster resource created successfully'
    test2Status="passed"
  else
    : 'Failed to create Cluster resource'
    test2Message="Failed to create Cluster resource via oc apply"
  fi
  
  test2Duration=$(($(date +%s) - test2Start))
  AddTestResult "test_cluster_creation" "$test2Status" "$test2Duration" "$test2Message"
else
  : 'Skipping Cluster creation (already exists)'
fi

# Test 3: Verify Cluster resource exists
: 'Test 3: Verify Cluster resource...'
test3Start=$(date +%s)
test3Status="failed"
test3Message=""

if oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  : 'Cluster resource verified'
  test3Status="passed"
else
  : 'Cluster resource not found after creation'
  test3Message="Cluster ${FA__SCALE__CLUSTER_NAME} not found in namespace ${FA__SCALE__NAMESPACE}"
fi

test3Duration=$(($(date +%s) - test3Start))
AddTestResult "test_cluster_exists" "$test3Status" "$test3Duration" "$test3Message"

# Test 4: Verify Cluster uses auto-discovery (bypassDiscovery NOT set)
: 'Test 4: Verify Cluster device configuration...'
test4Start=$(date +%s)
test4Status="failed"
test4Message=""

bypassDiscovery=$(oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" \
  -o jsonpath='{.spec.daemon.nsdDevicesConfig.bypassDiscovery}')

if [[ "$bypassDiscovery" == "false" ]]; then
  : 'Cluster configured for auto-discovery (FusionAccess shared SAN pattern)'
  test4Status="passed"
else
  : "WARNING: bypassDiscovery is '${bypassDiscovery}', expected 'false' for auto-discovery"
  test4Message="Cluster should have bypassDiscovery: false for shared SAN storage"
fi

test4Duration=$(($(date +%s) - test4Start))
AddTestResult "test_cluster_auto_discovery" "$test4Status" "$test4Duration" "$test4Message"

: 'Cluster Status:'
if ! oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}"; then
  : 'Cluster not found'
fi

: 'Cluster created with bypassDiscovery: false (auto-discovery mode)'

true
