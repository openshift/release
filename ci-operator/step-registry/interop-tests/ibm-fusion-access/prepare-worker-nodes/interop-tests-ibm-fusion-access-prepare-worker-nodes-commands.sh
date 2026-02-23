#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# JUnit XML test results configuration
junitResultsFile="${ARTIFACT_DIR}/junit_prepare_worker_nodes_tests.xml"
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
  typeset testClassName="${1:-PrepareWorkerNodesTests}"; (($#)) && shift
  
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
  <testsuite name="Prepare Worker Nodes Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : '📊 Test Results Summary:'
  : "  Total Tests: ${testsTotal}"
  : "  Passed: ${testsPassed}"
  : "  Failed: ${testsFailed}"
  : "  Duration: ${totalDuration}s"
  : "  Results File: ${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename ${junitResultsFile})"
    : '  ✅ Results copied to SHARED_DIR'
  fi
  
  # Exit with failure if any tests failed
  if [[ ${testsFailed} -gt 0 ]]; then
    : "❌ Test suite failed: ${testsFailed} test(s) failed"
    exit 1
  fi

  true
}

# Trap to ensure JUnit XML is generated even on failure
trap GenerateJunitXml EXIT

: '🔧 Preparing worker nodes for IBM Storage Scale...'

# Get worker nodes
workerNodes=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
workerCount=$(echo "$workerNodes" | wc -l)

# Validate that we have worker nodes
if [[ -z "${workerNodes}" ]] || [[ "${workerCount}" -eq 0 ]]; then
  : '❌ ERROR: No worker nodes found'
  oc get nodes
  exit 1
fi

: "Found ${workerCount} worker nodes"

# Function to create and verify directory on node
CreateDirectoryOnNode() {
  typeset node="${1}"; (($#)) && shift
  typeset dir="${1}"; (($#)) && shift
  
  : "  Creating $dir..."
  
  # Create directory - let errors propagate
  if ! oc debug -n default node/"$node" -- chroot /host mkdir -p "$dir" >/dev/null; then
    : "  ❌ Failed to create $dir on $node"
    return 1
  fi
  
  # Verify directory actually exists
  if ! oc debug -n default node/"$node" -- chroot /host test -d "$dir" >/dev/null; then
    : "  ❌ Directory $dir does not exist on $node after creation attempt"
    return 1
  fi
  
  : "  ✅ $dir created and verified on $node"

  true
}

# Create required directories on each worker node
: 'Creating required directories on worker nodes...'
for node in $workerNodes; do
  : "🧪 Test: Prepare node ${node}..."
  testStart=$(date +%s)
  testStatus="failed"
  testMessage=""
  
  : "Processing node: $node"
  
  # Track which directories failed
  failedDirs=()
  
  # Create /var/lib/firmware directory (required by mmbuildgpl for kernel module build)
  if ! CreateDirectoryOnNode "$node" "/var/lib/firmware"; then
    failedDirs+=("/var/lib/firmware")
  fi
  
  # Create /var/mmfs directories (required by IBM Storage Scale)
  if ! CreateDirectoryOnNode "$node" "/var/mmfs/etc"; then
    failedDirs+=("/var/mmfs/etc")
  fi
  
  if ! CreateDirectoryOnNode "$node" "/var/mmfs/tmp/traces"; then
    failedDirs+=("/var/mmfs/tmp/traces")
  fi
  
  if ! CreateDirectoryOnNode "$node" "/var/mmfs/pmcollector"; then
    failedDirs+=("/var/mmfs/pmcollector")
  fi
  
  # Check if all directories were created successfully
  if [ ${#failedDirs[@]} -eq 0 ]; then
    : "  ✅ All directories created successfully on $node"
    testStatus="passed"
  else
    : "  ❌ Failed to prepare node: $node"
    testMessage="Failed to create directories on node ${node}: ${failedDirs[*]}"
  fi
  
  testDuration=$(($(date +%s) - testStart))
  # Sanitize node name for XML (replace dots and dashes)
  sanitizedNode=$(echo "$node" | tr '.-' '__')
  AddTestResult "test_prepare_node_${sanitizedNode}" "$testStatus" "$testDuration" "$testMessage"
done

: '✅ Worker node preparation completed!'
: 'All nodes are ready for IBM Storage Scale daemon deployment'

true
