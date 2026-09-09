#!/bin/bash

set -euo pipefail

echo "Symlinking oc as kubectl..."
mkdir -p /tmp/bin
ln -sf "$(which oc)" /tmp/bin/kubectl
export PATH="/tmp/bin:${PATH}"

echo "Installing crane..."
GOFLAGS="" go install github.com/google/go-containerregistry/cmd/crane@latest

echo "Downloading chainsaw..."
mkdir -p bin
make chainsaw

REPORT_ARGS="--report-path ${ARTIFACT_DIR} --report-format XML"
ASSERT_TIMEOUT="--assert-timeout 20m"

echo "Running chainsaw e2e tests..."
make test-e2e CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_e2e ${REPORT_ARGS} ${ASSERT_TIMEOUT}"

echo "Running chainsaw ca-rotation tests..."
make test-e2e-destructive CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_ca_rotation ${REPORT_ARGS} ${ASSERT_TIMEOUT}"

echo "Chainsaw e2e tests completed"
