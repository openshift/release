#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Judge ==="

set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
set -x

EVAL_CONFIG_DIR="/opt/ai-helpers/evals/jira-solver"

if [[ ! -f "${EVAL_CONFIG_DIR}/eval.yaml" ]]; then
    cat > /tmp/eval.yaml <<'EVALCFG'
name: jira-solver-eval
init:
  repo: "${UPSTREAM_REPO}"
dataset:
  path: /opt/ai-helpers/evals/jira-solver/cases
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
  - name: pr_description_exists
  - name: diff_size_ratio
  - name: function_overlap
thresholds: {}
EVALCFG
    sed -i "s|\${UPSTREAM_REPO}|${UPSTREAM_REPO}|g" /tmp/eval.yaml
    EVAL_CONFIG="/tmp/eval.yaml"
else
    EVAL_CONFIG="${EVAL_CONFIG_DIR}/eval.yaml"
fi

prow-agent-eval judge \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --artifact-dir="${ARTIFACT_DIR}"

echo "=== TRT Eval Judge Complete ==="
