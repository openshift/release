#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Init ==="

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_EVAL_CASE:-}" ]]; then
    EVAL_CASE="${MULTISTAGE_PARAM_OVERRIDE_EVAL_CASE}"
fi

set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
set -x

EVAL_CONFIG="/opt/ai-helpers/evals/trt-agentic-solve/solve-eval.yaml"

CASE_FLAG=""
if [[ -n "${EVAL_CASE:-}" ]]; then
    CASE_FLAG="--case=${EVAL_CASE}"
fi

prow-agent-eval init \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --mode=solve \
    ${CASE_FLAG}

echo "=== TRT Eval Init Complete ==="
