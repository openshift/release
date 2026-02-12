#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting AWS Neuron operator E2E tests"

# Set up kubeconfig
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Run eco-gotests with neuron test suite
cd /home/testuser

# Export all ECO_HWACCEL_NEURON_* environment variables for the test
export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-neuron}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-neuron}"

echo "Running tests with features: ${ECO_TEST_FEATURES}"
echo "Running tests with labels: ${ECO_TEST_LABELS}"

# Run the neuron tests
ginkgo --label-filter="${ECO_TEST_LABELS}" \
    --timeout=2h \
    --v \
    ./tests/hw-accel/neuron/...

echo "AWS Neuron operator E2E tests completed"
