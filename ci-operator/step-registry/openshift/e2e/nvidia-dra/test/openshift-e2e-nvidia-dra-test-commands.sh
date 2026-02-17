#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "NVIDIA DRA Test Execution"
echo "========================================="
echo "Test Suite: ${DRA_TEST_SUITE}"
echo "GPU Type: ${GPU_TYPE}"
echo "GPU Architecture: ${GPU_ARCHITECTURE}"
echo "MIG Capable: ${GPU_MIG_CAPABLE}"
echo "Skip Prerequisites: ${DRA_SKIP_PREREQUISITES}"
echo ""

# Export kubeconfig
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
oc wait --for=condition=Ready nodes --all --timeout=10m

# Verify GPU nodes are present
echo "Checking for GPU nodes..."
GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | wc -l)
echo "Found ${GPU_NODES} GPU node(s) in cluster"

if [ "${GPU_NODES}" -eq 0 ]; then
    echo "WARNING: No GPU nodes found in cluster!"
    echo "Checking all node labels for debugging:"
    oc get nodes --show-labels
    echo ""
    echo "NOTE: Tests will skip automatically if no GPU nodes are available"
    echo "This is expected behavior on non-GPU clusters"
fi

# Determine which tests to run based on suite
case "${DRA_TEST_SUITE}" in
  basic)
    TESTS=(
      "[sig-scheduling] NVIDIA DRA Basic GPU Allocation should allocate single GPU to pod via DRA [Suite:openshift/conformance/parallel]"
      "[sig-scheduling] NVIDIA DRA Basic GPU Allocation should handle pod deletion and resource cleanup [Suite:openshift/conformance/parallel]"
    )
    ;;

  multi-gpu)
    TESTS=(
      "[sig-scheduling] NVIDIA DRA Multi-GPU Workloads should allocate multiple GPUs to single pod [Suite:openshift/conformance/parallel]"
    )
    ;;

  partitionable)
    if [ "${GPU_MIG_CAPABLE}" != "true" ]; then
      echo "WARNING: GPU does not support MIG, partitionable tests will be skipped"
    fi
    TESTS=(
      "[sig-scheduling] NVIDIA DRA Partitionable Devices should allocate MIG partition to pod [Suite:openshift/conformance/parallel]"
      "[sig-scheduling] NVIDIA DRA Partitionable Devices should support time-sliced GPU sharing [Suite:openshift/conformance/parallel]"
    )
    ;;

  all)
    TESTS=(
      "[sig-scheduling] NVIDIA DRA Basic GPU Allocation should allocate single GPU to pod via DRA [Suite:openshift/conformance/parallel]"
      "[sig-scheduling] NVIDIA DRA Basic GPU Allocation should handle pod deletion and resource cleanup [Suite:openshift/conformance/parallel]"
      "[sig-scheduling] NVIDIA DRA Multi-GPU Workloads should allocate multiple GPUs to single pod [Suite:openshift/conformance/parallel]"
    )
    # Add partitionable tests if GPU supports MIG
    if [ "${GPU_MIG_CAPABLE}" == "true" ]; then
      TESTS+=(
        "[sig-scheduling] NVIDIA DRA Partitionable Devices should allocate MIG partition to pod [Suite:openshift/conformance/parallel]"
        "[sig-scheduling] NVIDIA DRA Partitionable Devices should support time-sliced GPU sharing [Suite:openshift/conformance/parallel]"
      )
    else
      echo "INFO: Skipping partitionable tests (GPU is not MIG-capable)"
    fi
    ;;

  *)
    echo "ERROR: Unknown test suite: ${DRA_TEST_SUITE}"
    exit 1
    ;;
esac

# Create artifacts directory for test results
mkdir -p "${ARTIFACT_DIR}/nvidia-dra"

# Run tests
echo ""
echo "Running ${#TESTS[@]} test(s)..."
echo ""

FAILED=0
PASSED=0
SKIPPED=0

for test in "${TESTS[@]}"; do
  echo "========================================="
  echo "Running: ${test}"
  echo "========================================="

  # Run test and capture exit code
  set +e
  openshift-tests run-test \
      -n "${test}" \
      -o "${ARTIFACT_DIR}/nvidia-dra/test-output.log" \
      --junit-dir="${ARTIFACT_DIR}/nvidia-dra/junit"
  EXIT_CODE=$?
  set -e

  if [ ${EXIT_CODE} -eq 0 ]; then
    echo "✓ PASSED"
    PASSED=$((PASSED + 1))
  else
    # Check if test was skipped (openshift-tests returns 0 for skips)
    # If exit code is non-zero, it's a failure
    echo "✗ FAILED (exit code: ${EXIT_CODE})"
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

# Summary
echo "========================================="
echo "Test Results Summary"
echo "========================================="
echo "Passed:  ${PASSED}"
echo "Failed:  ${FAILED}"
echo "Skipped: ${SKIPPED}"
echo ""

# Save summary to artifact
cat > "${ARTIFACT_DIR}/nvidia-dra/summary.txt" <<EOF
NVIDIA DRA Test Results
========================
Test Suite: ${DRA_TEST_SUITE}
GPU Type: ${GPU_TYPE}
GPU Architecture: ${GPU_ARCHITECTURE}
GPU Nodes Found: ${GPU_NODES}

Results:
--------
Passed:  ${PASSED}
Failed:  ${FAILED}
Skipped: ${SKIPPED}
Total:   ${#TESTS[@]}

Status: $([ ${FAILED} -eq 0 ] && echo "SUCCESS" || echo "FAILED")
EOF

if [ ${FAILED} -gt 0 ]; then
  echo "Result: FAILED"
  exit 1
else
  echo "Result: SUCCESS"
  exit 0
fi
