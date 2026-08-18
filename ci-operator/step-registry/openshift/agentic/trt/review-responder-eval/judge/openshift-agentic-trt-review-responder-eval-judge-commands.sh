#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Judge ==="

# Disable tracing while loading secret
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN

EVAL_CONFIG="${EVAL_CONFIG:-/opt/ai-helpers/evals/review-responder/review-responder-eval.yaml}"

prow-agent-eval-python judge \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --artifact-dir="${ARTIFACT_DIR}" \
    --mode=followup

echo "=== TRT Review Responder Eval Judge Complete ==="
