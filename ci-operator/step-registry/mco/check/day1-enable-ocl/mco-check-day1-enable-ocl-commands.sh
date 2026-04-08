#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Function to create junit XML for test results
function create_junit() {
  local test_name="$1"
  local result="$2"
  local message="$3"

  if [ "$result" == "pass" ]; then
    cat >"${ARTIFACT_DIR}/junit_mco_day1_ocl_check.xml" <<EOF
<testsuite name="MCO Day1 OCL Verification" tests="1" failures="0">
  <testcase name="$test_name"/>
</testsuite>
EOF
  else
    cat >"${ARTIFACT_DIR}/junit_mco_day1_ocl_check.xml" <<EOF
<testsuite name="MCO Day1 OCL Verification" tests="1" failures="1">
  <testcase name="$test_name">
    <failure message="">$message</failure>
  </testcase>
</testsuite>
EOF
  fi
}

# Function to log and fail
function fail_test() {
  local message="$1"
  echo "FAIL: $message"
  create_junit "[sig-mco][PolarionID:86148] Verify OCL install time support" "fail" "$message"
  exit 1
}

# Function to log and pass
function pass_test() {
  local message="$1"
  echo "PASS: $message"
  create_junit "[sig-mco][PolarionID:86148] Verify OCL install time support" "pass" ""
  exit 0
}

echo "============================================"
echo "MCO Day1 OCL Verification"
echo "============================================"

# Check if mcps file exists
if [ ! -f "${SHARED_DIR}/mco-day1-ocl-mcps" ]; then
  fail_test "MCPs file not found at ${SHARED_DIR}/mco-day1-ocl-mcps. The enable-ocl step may not have run."
fi

# Read MCPs and check if empty (step was skipped)
MCPS=$(cat "${SHARED_DIR}/mco-day1-ocl-mcps")
if [ -z "$MCPS" ]; then
  echo "MCPs configuration is empty. The enable-ocl step was skipped. Skipping verification."
  exit 0
fi

# Read the image reference and rendered image push spec
if [ ! -f "${SHARED_DIR}/mco-day1-ocl-image-reference" ]; then
  fail_test "Image reference file not found at ${SHARED_DIR}/mco-day1-ocl-image-reference. The enable-ocl step may not have completed successfully."
fi

if [ ! -f "${SHARED_DIR}/mco-day1-ocl-rendered-image-push-spec" ]; then
  fail_test "Rendered image push spec file not found at ${SHARED_DIR}/mco-day1-ocl-rendered-image-push-spec"
fi

IMAGE_REFERENCE=$(cat "${SHARED_DIR}/mco-day1-ocl-image-reference")
RENDERED_IMAGE_PUSH_SPEC=$(cat "${SHARED_DIR}/mco-day1-ocl-rendered-image-push-spec")

echo "Image reference: $IMAGE_REFERENCE"
echo "MCPs with OCL enabled: $MCPS"
echo "Rendered image push spec: $RENDERED_IMAGE_PUSH_SPEC"
echo ""

# Extract the repository from the rendered image push spec (e.g., quay.io/mcoqe/layering from quay.io/mcoqe/layering:latest)
RENDERED_REPOSITORY=$(echo "$RENDERED_IMAGE_PUSH_SPEC" | sed 's/:.*$//')
echo "Rendered image repository: $RENDERED_REPOSITORY"
echo ""

# The search string we're looking for in logs
SEARCH_STRING="Executing rebase to ${IMAGE_REFERENCE}"
echo "Search string: $SEARCH_STRING"
echo ""

# Get all MachineConfigPools
ALL_MCPS=$(oc get mcp -o jsonpath='{.items[*].metadata.name}')
echo "All MCPs in cluster: $ALL_MCPS"
echo ""

# Track verification results
FAILURES=""
CHECKS_PASSED=0
CHECKS_TOTAL=0

# Check each MCP that should have OCL enabled
for mcp in $MCPS; do
  echo "Checking MCP: $mcp (should have OCL)"
  echo "-------------------------------------------"

  # Get nodes in this pool
  NODES=$(oc get nodes -l "node-role.kubernetes.io/$mcp=" -o jsonpath='{.items[*].metadata.name}' || echo "")

  if [ -z "$NODES" ]; then
    echo "WARNING: No nodes found for MCP $mcp"
    FAILURES="${FAILURES}\nNo nodes found for MCP $mcp with OCL enabled"
    continue
  fi

  echo "Nodes in $mcp: $NODES"

  # Check each node
  for node in $NODES; do
    echo "  Checking node: $node"

    # Check 1: Verify rebase message in logs
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    echo "    [Check 1/2] Verifying rebase message in firstboot logs..."

    # Get the machine-config-daemon-firstboot.service logs
    LOGS=$(oc debug -n default node/"$node" -- chroot /host journalctl -u machine-config-daemon-firstboot.service 2>&1 || echo "")

    if [ -z "$LOGS" ]; then
      echo "    WARNING: Could not retrieve logs from $node"
      FAILURES="${FAILURES}\nCould not retrieve machine-config-daemon-firstboot.service logs from node $node (MCP: $mcp)"
    else
      # Check if the rebase message appears in the logs
      if echo "$LOGS" | grep -qF "$SEARCH_STRING"; then
        echo "    ✓ Found '$SEARCH_STRING' in logs"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
      else
        echo "    ✗ '$SEARCH_STRING' NOT found in logs"
        echo "    DEBUG: Printing machine-config-daemon-firstboot.service logs from node $node:"
        echo "    =================================================="
        echo "$LOGS" | sed 's/^/    /'
        echo "    =================================================="
        FAILURES="${FAILURES}\n'$SEARCH_STRING' not found in machine-config-daemon-firstboot.service logs on node $node (MCP: $mcp)"
      fi
    fi

    # Check 2: Verify rpm-ostree status shows rendered image from correct repository
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    echo "    [Check 2/2] Verifying rpm-ostree status shows image from $RENDERED_REPOSITORY..."

    # Get rpm-ostree status
    OSTREE_STATUS=$(oc debug -n default node/"$node" -- chroot /host rpm-ostree status 2>&1 || echo "")

    if [ -z "$OSTREE_STATUS" ]; then
      echo "    WARNING: Could not retrieve rpm-ostree status from $node"
      FAILURES="${FAILURES}\nCould not retrieve rpm-ostree status from node $node (MCP: $mcp)"
    else
      # Check if the rendered repository appears in rpm-ostree status
      if echo "$OSTREE_STATUS" | grep -q "$RENDERED_REPOSITORY"; then
        echo "    ✓ Node is using image from $RENDERED_REPOSITORY"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
      else
        echo "    ✗ Node is NOT using image from $RENDERED_REPOSITORY"
        echo "    DEBUG: Printing rpm-ostree status from node $node:"
        echo "    =================================================="
        echo "$OSTREE_STATUS" | sed 's/^/    /'
        echo "    =================================================="
        FAILURES="${FAILURES}\nNode $node (MCP: $mcp) is not using image from repository $RENDERED_REPOSITORY"
      fi
    fi
  done
  echo ""
done

# Check MCPs that should NOT have OCL enabled
echo "Checking MCPs without OCL deployment"
echo "-------------------------------------------"
for mcp in $ALL_MCPS; do
  # Skip if this MCP is in the OCL-enabled list
  if echo "$MCPS" | grep -qw "$mcp"; then
    continue
  fi

  echo "Checking MCP: $mcp (should NOT have OCL)"

  # Get nodes in this pool
  NODES=$(oc get nodes -l "node-role.kubernetes.io/$mcp=" -o jsonpath='{.items[*].metadata.name}' || echo "")

  if [ -z "$NODES" ]; then
    echo "  No nodes found for MCP $mcp (skipping)"
    continue
  fi

  echo "Nodes in $mcp: $NODES"

  # Check each node
  for node in $NODES; do
    echo "  Checking node: $node"

    # Check 1: Verify rebase message NOT in logs
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    echo "    [Check 1/2] Verifying rebase message NOT in firstboot logs..."

    # Get the machine-config-daemon-firstboot.service logs
    LOGS=$(oc debug -n default node/"$node" -- chroot /host journalctl -u machine-config-daemon-firstboot.service 2>&1 || echo "")

    if [ -z "$LOGS" ]; then
      echo "    WARNING: Could not retrieve logs from $node"
    else
      # Check that the rebase message does NOT appear in the logs
      if echo "$LOGS" | grep -qF "$SEARCH_STRING"; then
        echo "    ✗ Found '$SEARCH_STRING' in logs (should not be present)"
        echo "    DEBUG: Printing machine-config-daemon-firstboot.service logs from node $node:"
        echo "    =================================================="
        echo "$LOGS" | sed 's/^/    /'
        echo "    =================================================="
        FAILURES="${FAILURES}\n'$SEARCH_STRING' unexpectedly found in machine-config-daemon-firstboot.service logs on node $node (MCP: $mcp, OCL not enabled)"
      else
        echo "    ✓ '$SEARCH_STRING' not found in logs (as expected)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
      fi
    fi

    # Check 2: Verify rpm-ostree status does NOT show rendered image from OCL repository
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    echo "    [Check 2/2] Verifying rpm-ostree status does NOT show image from $RENDERED_REPOSITORY..."

    # Get rpm-ostree status
    OSTREE_STATUS=$(oc debug -n default node/"$node" -- chroot /host rpm-ostree status 2>&1 || echo "")

    if [ -z "$OSTREE_STATUS" ]; then
      echo "    WARNING: Could not retrieve rpm-ostree status from $node"
    else
      # Check that the rendered repository does NOT appear in rpm-ostree status
      if echo "$OSTREE_STATUS" | grep -q "$RENDERED_REPOSITORY"; then
        echo "    ✗ Node is using image from $RENDERED_REPOSITORY (should not be present)"
        echo "    DEBUG: Printing rpm-ostree status from node $node:"
        echo "    =================================================="
        echo "$OSTREE_STATUS" | sed 's/^/    /'
        echo "    =================================================="
        FAILURES="${FAILURES}\nNode $node (MCP: $mcp, OCL not enabled) is unexpectedly using image from repository $RENDERED_REPOSITORY"
      else
        echo "    ✓ Node is NOT using image from $RENDERED_REPOSITORY (as expected)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
      fi
    fi
  done
  echo ""
done

# Summary
echo "============================================"
echo "Verification Summary"
echo "============================================"
echo "Total checks performed: $CHECKS_TOTAL"
echo "Checks passed: $CHECKS_PASSED"
echo ""

if [ -n "$FAILURES" ]; then
  echo "FAILURES:"
  echo -e "$FAILURES"
  fail_test "Day1 OCL verification failed. $CHECKS_PASSED/$CHECKS_TOTAL checks passed.$FAILURES"
else
  pass_test "All Day1 OCL verification checks passed. $CHECKS_PASSED/$CHECKS_TOTAL checks successful."
fi
