#!/bin/bash

set -euo pipefail

tool_path=/usr/local/bin/kubectl-dev_tool

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

echo "kubectl-dev_tool available in the e2e test image at ${tool_path}"
