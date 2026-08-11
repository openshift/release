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

# CI pods expose in-cluster env (build farm). Without forcing kubeconfig,
# the MCP server auto-selects in-cluster and gets RBAC denials. Unset the
# env signals and pass --kubeconfig/--cluster-provider for the IPI cluster.
unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT

MCP_PORT="${MCP_PORT:-8080}"
# Matches Makefile BINARY_NAME in openshift/openshift-mcp-server
# (go build -o kubernetes-mcp-server).
BINARY_NAME="${BINARY_NAME:-kubernetes-mcp-server}"
if [[ ! -x "./${BINARY_NAME}" ]]; then
    echo "ERROR: ./${BINARY_NAME} not found after make build; directory contents:" >&2
    ls -la ./"${BINARY_NAME}"* ./openshift-mcp-server* 2>/dev/null || ls -la
    exit 1
fi
./"${BINARY_NAME}" \
    --port "${MCP_PORT}" \
    --toolsets "${TOOLSETS}" \
    --config-dir "${MCP_CONFIG_DIR}" \
    --kubeconfig "${KUBECONFIG}" \
    --cluster-provider kubeconfig \
    --read-only=false \
    >"${ARTIFACT_DIR}/mcp-server.log" 2>&1 \
    & echo $! > .mcp-server.pid

elapsed=0
while [ "${elapsed}" -lt 60 ]; do
    if curl -fsS "http://localhost:${MCP_PORT}/healthz" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
if ! curl -fsS "http://localhost:${MCP_PORT}/healthz" >/dev/null 2>&1; then
    echo "ERROR: MCP server failed to become ready" >&2
    echo "=== ${ARTIFACT_DIR}/mcp-server.log ===" >&2
    cat "${ARTIFACT_DIR}/mcp-server.log" >&2 || true
    exit 1
fi

make run-evals EVAL_CONFIG="${EVAL_CONFIG}" EVAL_LABEL_SELECTOR="${EVAL_LABEL_SELECTOR}"

RESULTS_FILE="$(find . -maxdepth 1 -name 'mcpchecker-*-out.json' | sort | tail -1)"
if [[ -z "${RESULTS_FILE}" ]]; then
    echo "ERROR: no mcpchecker results file found" >&2
    exit 1
fi

MCPCHECKER="$(pwd)/_output/tools/bin/mcpchecker"
cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/mcpchecker-out.json"

# Emit JUnit before verify so Spyglass/Sippy still get artifacts when the
# pass-rate gate fails.
"${MCPCHECKER}" result convert junit "${ARTIFACT_DIR}/mcpchecker-out.json" \
    --output-file "${ARTIFACT_DIR}/junit_mcpchecker.xml"

if [[ "${TASK_PASS_RATE}" != "0.0" || "${ASSERTION_PASS_RATE}" != "0.0" ]]; then
    "${MCPCHECKER}" result verify "${ARTIFACT_DIR}/mcpchecker-out.json" \
        --task "${TASK_PASS_RATE}" --assertion "${ASSERTION_PASS_RATE}"
fi
