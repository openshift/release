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
export AGENT_EVAL_RUNS_DIR="${ARTIFACT_DIR}/eval/runs"
EVAL_NAME=$(python3 - "${EVAL_CONFIG}" <<'PY'
import sys

from agent_eval.config import EvalConfig

print(EvalConfig.from_yaml(sys.argv[1]).eval_name())
PY
)
RUN_DIR="${AGENT_EVAL_RUNS_DIR}/${EVAL_NAME}/${EVAL_NAME}"
mkdir -p "${RUN_DIR}"
rm -f "${RUN_DIR}/run_result.json"
if [[ -f "${SHARED_DIR}/eval-solve-run-result.json" ]]; then
    cp "${SHARED_DIR}/eval-solve-run-result.json" "${RUN_DIR}/run_result.json"
fi

set +o errexit
prow-agent-eval judge \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --artifact-dir="${ARTIFACT_DIR}" \
    --mode=solve
JUDGE_STATUS=$?
set -o errexit

echo "=== TRT Eval Judge Complete ==="
exit "${JUDGE_STATUS}"
