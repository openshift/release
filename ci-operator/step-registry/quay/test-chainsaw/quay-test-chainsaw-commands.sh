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

# STS runs first because the destructive suite degrades the cluster; a failure
# fails the step at the end, after the selected suite has run.
sts_rc=0
if [[ "${QUAY_OPERATOR_STS}" == "true" || "${CHAINSAW_SUITE}" == "sts" ]]; then
  echo "Installing jq for the STS suite..."
  GOFLAGS="" GOBIN=/tmp/bin GOMODCACHE=/tmp/gomodcache GOCACHE=/tmp/gocache go install github.com/itchyny/gojq/cmd/gojq@v0.12.17
  ln -sf /tmp/bin/gojq /tmp/bin/jq

  echo "Running chainsaw STS tests..."
  make test-e2e-sts \
    STS_TEST_NAMESPACE="$(cat "${SHARED_DIR}/STS_TEST_NAMESPACE")" \
    STS_S3_BUCKET="$(cat "${SHARED_DIR}/STS_S3_BUCKET")" \
    STS_S3_REGION="$(cat "${SHARED_DIR}/STS_S3_REGION")" \
    STS_ROLE_ARN="$(cat "${SHARED_DIR}/STS_ROLE_ARN")" \
    CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_sts ${REPORT_ARGS} ${ASSERT_TIMEOUT}" || sts_rc=1
fi

case "${CHAINSAW_SUITE}" in
all)
  # Destructive runs last (it degrades the cluster) and even when e2e fails;
  # the step fails if either suite failed.
  rc=0
  echo "Running chainsaw e2e tests..."
  make test-e2e CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_e2e ${REPORT_ARGS} ${ASSERT_TIMEOUT}" || rc=1

  echo "Running chainsaw destructive (ca-rotation, postgres-tls-lifecycle) tests..."
  make test-e2e-destructive CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_ca_rotation ${REPORT_ARGS} ${ASSERT_TIMEOUT}" || rc=1

  if [[ "${rc}" -ne 0 ]]; then
    echo "Chainsaw e2e and/or destructive tests failed" >&2
    exit 1
  fi
  ;;
e2e)
  echo "Running chainsaw e2e tests..."
  make test-e2e CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_e2e ${REPORT_ARGS} ${ASSERT_TIMEOUT}"
  ;;
sts)
  ;;
destructive)
  echo "Running chainsaw destructive (ca-rotation, postgres-tls-lifecycle) tests..."
  make test-e2e-destructive CHAINSAW_PARALLEL=1 CHAINSAW_EXTRA_ARGS="--report-name junit_chainsaw_destructive ${REPORT_ARGS} ${ASSERT_TIMEOUT}"
  ;;
*)
  echo "Unknown CHAINSAW_SUITE '${CHAINSAW_SUITE}': valid values are all, e2e, destructive, sts" >&2
  exit 1
  ;;
esac

if [[ "${sts_rc}" -ne 0 ]]; then
  echo "Chainsaw STS tests failed" >&2
  exit 1
fi

echo "Chainsaw e2e tests completed"
