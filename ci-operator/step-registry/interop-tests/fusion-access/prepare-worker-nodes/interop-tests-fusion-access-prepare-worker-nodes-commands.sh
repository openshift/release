#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_prepare_worker_nodes_tests.xml"
TEST_START_TIME=$(date +%s)
TESTS_TOTAL=0
TESTS_FAILED=0
TESTS_PASSED=0
TEST_CASES=""

# Function to add test result to JUnit XML
add_test_result() {
  local test_name="$1"
  local test_status="$2"  # "passed" or "failed"
  local test_duration="$3"
  local test_message="${4:-}"
  local test_classname="${5:-PrepareWorkerNodesTests}"
  
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  
  if [[ "$test_status" == "passed" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\"/>"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\">
      <failure message=\"Test failed\">${test_message}</failure>
    </testcase>"
  fi
}

# Function to generate JUnit XML report
generate_junit_xml() {
  local total_duration=$(($(date +%s) - TEST_START_TIME))
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Prepare Worker Nodes Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
${TEST_CASES}
  </testsuite>
</testsuites>
EOF
  
  echo ""
  echo "📊 Test Results Summary:"
  echo "  Total Tests: ${TESTS_TOTAL}"
  echo "  Passed: ${TESTS_PASSED}"
  echo "  Failed: ${TESTS_FAILED}"
  echo "  Duration: ${total_duration}s"
  echo "  Results File: ${JUNIT_RESULTS_FILE}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/$(basename ${JUNIT_RESULTS_FILE})"
    echo "  ✅ Results copied to SHARED_DIR"
  fi
  
  # Exit with failure if any tests failed
  if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo ""
    echo "❌ Test suite failed: ${TESTS_FAILED} test(s) failed"
    exit 1
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "🔧 Preparing worker nodes for IBM Storage Scale..."

# Get worker nodes
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l)

# Validate that we have worker nodes
if [[ -z "${WORKER_NODES}" ]] || [[ "${WORKER_COUNT}" -eq 0 ]]; then
  echo "❌ ERROR: No worker nodes found"
  oc get nodes
  exit 1
fi

echo "Found $WORKER_COUNT worker nodes:"
echo "$WORKER_NODES"
echo ""

# Function to create and verify directory on node
create_directory_on_node() {
  local node=$1
  local dir=$2
  
  echo "  Creating $dir..."
  
  # Create directory and capture full output
  local output
  output=$(oc debug -n default node/"$node" -- chroot /host mkdir -p "$dir" 2>&1 || true)
  
  # Filter out expected debug pod messages
  local filtered
  filtered=$(echo "$output" | grep -v "Starting pod\|Removing debug pod\|To use host binaries" | grep -v "^$" || true)
  
  # Check for error indicators in output
  if echo "$filtered" | grep -qiE "error|unable to|not found|cannot|failed|permission denied"; then
    echo "  ❌ Failed to create $dir on $node:"
    echo "$filtered" | sed 's/^/     /'
    return 1
  fi
  
  # Verify directory actually exists
  if ! oc debug -n default node/"$node" -- chroot /host test -d "$dir" >/dev/null 2>&1; then
    echo "  ❌ Directory $dir does not exist on $node after creation attempt"
    return 1
  fi
  
  echo "  ✅ $dir created and verified on $node"
  return 0
}

# Create required directories on each worker node
echo "Creating required directories on worker nodes..."
for node in $WORKER_NODES; do
  echo ""
  echo "🧪 Test: Prepare node ${node}..."
  test_start=$(date +%s)
  test_status="failed"
  test_message=""
  
  echo "Processing node: $node"
  
  # Track which directories failed
  failed_dirs=()
  
  # Create /var/lib/firmware directory (required by mmbuildgpl for kernel module build)
  if ! create_directory_on_node "$node" "/var/lib/firmware"; then
    failed_dirs+=("/var/lib/firmware")
  fi
  
  # Create /var/mmfs directories (required by IBM Storage Scale)
  if ! create_directory_on_node "$node" "/var/mmfs/etc"; then
    failed_dirs+=("/var/mmfs/etc")
  fi
  
  if ! create_directory_on_node "$node" "/var/mmfs/tmp/traces"; then
    failed_dirs+=("/var/mmfs/tmp/traces")
  fi
  
  if ! create_directory_on_node "$node" "/var/mmfs/pmcollector"; then
    failed_dirs+=("/var/mmfs/pmcollector")
  fi
  
  # Check if all directories were created successfully
  if [ ${#failed_dirs[@]} -eq 0 ]; then
    echo "  ✅ All directories created successfully on $node"
    test_status="passed"
  else
    echo "  ❌ Failed to prepare node: $node"
    test_message="Failed to create directories on node ${node}: ${failed_dirs[*]}"
  fi
  
  test_duration=$(($(date +%s) - test_start))
  # Sanitize node name for XML (replace dots and dashes)
  sanitized_node=$(echo "$node" | tr '.-' '__')
  add_test_result "test_prepare_node_${sanitized_node}" "$test_status" "$test_duration" "$test_message"
done

echo ""
echo "✅ Worker node preparation completed!"
echo "All nodes are ready for IBM Storage Scale daemon deployment"

