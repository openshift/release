#!/bin/bash

set -euo pipefail

# Clusterless label-filter gate for candidate (and similar) jobs.
# Failing here skips remaining pre/test steps, including IPI install.
# A cluster_profile lease is still held for the job; only AWS IPI is avoided.
# See the step documentation for why empty candidate suites stay red.

if [[ -z "${ECO_TEST_FEATURES:-}" ]]; then
  echo "ECO_TEST_FEATURES is required" >&2
  exit 1
fi

if [[ -z "${ECO_TEST_LABELS:-}" ]]; then
  echo "ECO_TEST_LABELS is required for label-filter preflight" >&2
  exit 1
fi

export ECO_DRY_RUN=true
export WORKLOAD_IMAGE="${WORKLOAD_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"
export KUBECONFIG="${KUBECONFIG:-/dev/null}"

echo "Label-filter preflight: features=${ECO_TEST_FEATURES} labels=${ECO_TEST_LABELS}"

make ginkgo
# Makefile run-tests does not forward args; call the runner with --dry-run.
ginkgo_ver="$(grep 'github.com/onsi/ginkgo/v2 ' go.mod | awk '{print $2}')"
export GINKGO="$(pwd)/bin/ginkgo/${ginkgo_ver}/ginkgo"
if [[ ! -x "${GINKGO}" ]]; then
  echo "ginkgo binary not found at ${GINKGO}" >&2
  exit 1
fi
scripts/test-runner.sh --dry-run
