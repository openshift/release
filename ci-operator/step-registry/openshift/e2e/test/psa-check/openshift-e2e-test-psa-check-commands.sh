#!/bin/bash

set -euo pipefail

: "${CLUSTER_DEBUG_TOOLS_VERSION:?CLUSTER_DEBUG_TOOLS_VERSION must be set}"

tool_dir="${SHARED_DIR}/cluster-debug-tools"
tool_path="${tool_dir}/kubectl-dev_tool"
mkdir -p "${tool_dir}"

echo "Installing cluster-debug-tools at ${CLUSTER_DEBUG_TOOLS_VERSION}"
GOBIN="${tool_dir}" GOFLAGS="" go install \
  "github.com/openshift/cluster-debug-tools/cmd/kubectl-dev_tool@${CLUSTER_DEBUG_TOOLS_VERSION}"

if [[ ! -x "${tool_path}" ]]; then
  echo "kubectl-dev_tool was not installed at ${tool_path}" >&2
  exit 1
fi

{
  printf 'export PSA_CHECK_BIN=%q\n' "${tool_path}"
  printf 'export PSA_CHECK_REQUIRED=true\n'
  if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    printf 'export ARTIFACT_PATH=%q\n' "${ARTIFACT_DIR}"
  fi
} >"${SHARED_DIR}/cluster-debug-tools.env"

echo "kubectl-dev_tool available at ${tool_path}"
