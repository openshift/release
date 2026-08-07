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

EVAL_CONFIG_DIR="/opt/ai-helpers/evals/jira-solver"

# Write eval config if not already present in the image
if [[ ! -f "${EVAL_CONFIG_DIR}/eval.yaml" ]]; then
    cat > /tmp/eval.yaml <<'EVALCFG'
name: jira-solver-eval
init:
  repo: "${UPSTREAM_REPO}"
dataset:
  path: cases
collect:
  build_result: true
  test_result: true
  expected_branch_diff: true
judges:
  - name: branch_created
  - name: pr_exists
  - name: build_passed
  - name: test_passed
  - name: file_overlap
thresholds: {}
EVALCFG
    sed -i "s|\${UPSTREAM_REPO}|${UPSTREAM_REPO}|g" /tmp/eval.yaml
    EVAL_CONFIG="/tmp/eval.yaml"
else
    EVAL_CONFIG="${EVAL_CONFIG_DIR}/eval.yaml"
fi

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
