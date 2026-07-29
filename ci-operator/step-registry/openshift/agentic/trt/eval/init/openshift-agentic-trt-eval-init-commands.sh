#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Init ==="

# --- Gangway override ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_EVAL_CASE:-}" ]]; then
    echo "Applying Gangway override: EVAL_CASE=${MULTISTAGE_PARAM_OVERRIDE_EVAL_CASE}"
    EVAL_CASE="${MULTISTAGE_PARAM_OVERRIDE_EVAL_CASE}"
fi

[[ -n "${EVAL_CASE:-}" ]] || { echo "ERROR: EVAL_CASE is required."; exit 1; }

CASES_DIR="/opt/ai-helpers/evals/jira-solver/cases/${EVAL_CASE}"
[[ -d "${CASES_DIR}" ]] || { echo "ERROR: Case directory not found: ${CASES_DIR}"; exit 1; }

INPUT_FILE="${CASES_DIR}/input.yaml"
[[ -f "${INPUT_FILE}" ]] || { echo "ERROR: input.yaml not found in ${CASES_DIR}"; exit 1; }

echo "Eval case: ${EVAL_CASE}"
echo "Cases dir: ${CASES_DIR}"

# --- Parse input.yaml ---
yaml_val() { grep "^${1}:" "${INPUT_FILE}" | cut -d' ' -f2-; }
JIRA_ISSUE_KEY=$(yaml_val jira_key)
BASE_BRANCH=$(yaml_val base_branch)
EXPECTED_BRANCH=$(yaml_val expected_branch)

echo "JIRA key: ${JIRA_ISSUE_KEY}"
echo "Base branch: ${BASE_BRANCH}"
echo "Expected branch: ${EXPECTED_BRANCH}"

# --- Write SHARED_DIR outputs ---
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"
cp "${CASES_DIR}/jira-issue.json" "${SHARED_DIR}/jira-issue.json"
echo "${BASE_BRANCH}" > "${SHARED_DIR}/eval-base-branch"
echo "${EXPECTED_BRANCH}" > "${SHARED_DIR}/eval-expected-branch"
echo "${EVAL_CASE}" > "${SHARED_DIR}/eval-case"

echo "Summary: $(jq -r '.fields.summary // .summary // "N/A"' "${SHARED_DIR}/jira-issue.json")"

echo "=== TRT Eval Init Complete ==="
