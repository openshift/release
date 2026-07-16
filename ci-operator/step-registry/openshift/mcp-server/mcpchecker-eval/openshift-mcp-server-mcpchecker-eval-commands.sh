#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Source credentials written by the preceding setup step
if [[ -f "${SHARED_DIR}/mcpchecker-creds.env" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/mcpchecker-creds.env"
fi

# The ipi-aws workflow provides oc; eval setup scripts expect kubectl
if ! command -v kubectl >/dev/null 2>&1; then
    mkdir -p /tmp/bin
    ln -s "$(command -v oc)" /tmp/bin/kubectl
    export PATH="/tmp/bin:${PATH}"
fi

PATH="${PATH}:$(pwd)/_output/tools/bin"
export PATH
export MCP_CONFIG_DIR=dev/config/mcp-configs

trap 'make stop-server || true' EXIT

GOFLAGS='-mod=readonly' make build
GOFLAGS='' make mcpchecker

make run-server TOOLSETS="${TOOLSETS}"
make run-evals EVAL_CONFIG="${EVAL_CONFIG}" EVAL_LABEL_SELECTOR="${EVAL_LABEL_SELECTOR}"

RESULTS_FILE="$(find . -maxdepth 1 -name 'mcpchecker-*-out.json' | sort | tail -1)"
if [[ -z "${RESULTS_FILE}" ]]; then
    echo "ERROR: no mcpchecker results file found" >&2
    exit 1
fi

MCPCHECKER="$(pwd)/_output/tools/bin/mcpchecker"
cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/mcpchecker-out.json"

"${MCPCHECKER}" result convert junit "${ARTIFACT_DIR}/mcpchecker-out.json" \
    --output-file "${ARTIFACT_DIR}/junit_mcpchecker.xml"

if [[ "${TASK_PASS_RATE}" != "0.0" || "${ASSERTION_PASS_RATE}" != "0.0" ]]; then
    "${MCPCHECKER}" result verify "${ARTIFACT_DIR}/mcpchecker-out.json" \
        --task "${TASK_PASS_RATE}" --assertion "${ASSERTION_PASS_RATE}"
fi
