#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Init ==="

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_EVAL_CASE:-}" ]]; then
    EVAL_CASE="${MULTISTAGE_PARAM_OVERRIDE_EVAL_CASE}"
fi

# Disable tracing while loading secret
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN

EVAL_CONFIG="${EVAL_CONFIG:-/opt/ai-helpers/evals/trt-agentic-solve/solve-eval.yaml}"

CASE_ARGS=()
if [[ -n "${EVAL_CASE:-}" ]]; then
    CASE_ARGS+=("--case=${EVAL_CASE}")
fi

prow-agent-eval-python init \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --mode=solve \
    "${CASE_ARGS[@]+"${CASE_ARGS[@]}"}"

echo "=== TRT Eval Init Complete ==="
