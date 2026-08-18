#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Init ==="

# Disable tracing while loading secret
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN

EVAL_CONFIG="${EVAL_CONFIG:-/opt/ai-helpers/evals/review-responder/review-responder-eval.yaml}"

CASE_ARGS=()
if [[ -n "${EVAL_CASE:-}" ]]; then
    CASE_ARGS+=("--case=${EVAL_CASE}")
fi

prow-agent-eval init \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --mode=followup \
    "${CASE_ARGS[@]+"${CASE_ARGS[@]}"}"

echo "=== TRT Review Responder Eval Init Complete ==="
