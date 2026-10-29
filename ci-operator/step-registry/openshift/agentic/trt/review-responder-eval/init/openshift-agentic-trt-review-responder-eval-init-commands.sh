#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Init ==="

SEED_TOKEN_FILE="/var/run/github-reviewer-token/token"
if [[ ! -f "${SEED_TOKEN_FILE}" ]]; then
    echo "ERROR: ${SEED_TOKEN_FILE} not found — mount trt-agentic-eval-gh-token"
    exit 1
fi

# Disable tracing while loading secrets
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
GITHUB_SEED_TOKEN=$(cat "${SEED_TOKEN_FILE}")
export GITHUB_SEED_TOKEN

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
