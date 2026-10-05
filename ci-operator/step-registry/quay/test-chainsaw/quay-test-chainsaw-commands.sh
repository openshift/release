#!/bin/bash

set -euo pipefail

echo "Symlinking oc as kubectl..."
mkdir -p /tmp/bin
ln -sf "$(which oc)" /tmp/bin/kubectl
export PATH="/tmp/bin:${PATH}"

echo "Installing crane..."
GOFLAGS="" GOBIN=/tmp/bin GOMODCACHE=/tmp/gomodcache GOCACHE=/tmp/gocache go install github.com/google/go-containerregistry/cmd/crane@v0.20.3

echo "Downloading chainsaw..."
mkdir -p bin
make chainsaw

REPORT_ARGS="--report-path ${ARTIFACT_DIR} --report-format XML"
ASSERT_TIMEOUT="--assert-timeout 20m"

case "${CHAINSAW_SUITE}" in
all)
  echo "Running chainsaw e2e tests..."
  make test-e2e CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_e2e ${REPORT_ARGS} ${ASSERT_TIMEOUT}"

  echo "Running chainsaw destructive (ca-rotation, postgres-tls-lifecycle) tests..."
  make test-e2e-destructive CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_ca_rotation ${REPORT_ARGS} ${ASSERT_TIMEOUT}"
  ;;
e2e)
  echo "Running chainsaw e2e tests..."
  make test-e2e CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_e2e ${REPORT_ARGS} ${ASSERT_TIMEOUT}"
  ;;
destructive)
  echo "Running chainsaw destructive (ca-rotation, postgres-tls-lifecycle) tests..."
  make test-e2e-destructive CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_destructive ${REPORT_ARGS} ${ASSERT_TIMEOUT}"
  ;;
*)
  echo "Unknown CHAINSAW_SUITE '${CHAINSAW_SUITE}': valid values are all, e2e, destructive" >&2
  exit 1
  ;;
esac

echo "Chainsaw e2e tests completed"
