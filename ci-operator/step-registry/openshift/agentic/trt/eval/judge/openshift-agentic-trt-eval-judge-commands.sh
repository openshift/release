#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Judge ==="

set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
set -x

EVAL_CONFIG="/opt/ai-helpers/evals/trt-agentic-solve/solve-eval.yaml"

prow-agent-eval judge \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --artifact-dir="${ARTIFACT_DIR}"

echo "=== TRT Eval Judge Complete ==="
