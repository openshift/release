#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Judge ==="

# Disable tracing while loading secret
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN

EVAL_CONFIG="${EVAL_CONFIG:-/opt/ai-helpers/evals/trt-agentic-solve/solve-eval.yaml}"

prow-agent-eval judge \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --artifact-dir="${ARTIFACT_DIR}" \
    --mode=solve

echo "=== TRT Eval Judge Complete ==="
