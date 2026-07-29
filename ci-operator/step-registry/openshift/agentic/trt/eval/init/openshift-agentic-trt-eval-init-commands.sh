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

ALL_CASES_DIR="/opt/ai-helpers/evals/jira-solver/cases"

# --- Build case list ---
CASE_LIST=()
if [[ -n "${EVAL_CASE:-}" ]]; then
    CASE_LIST=("${EVAL_CASE}")
else
    for d in "${ALL_CASES_DIR}"/*/; do
        CASE_LIST+=("$(basename "$d")")
    done
fi

[[ ${#CASE_LIST[@]} -gt 0 ]] || { echo "ERROR: No eval cases found."; exit 1; }
echo "Cases to run: ${CASE_LIST[*]}"

# --- Set up per-case metadata ---
yaml_val() { grep "^${1}:" "$2" | cut -d' ' -f2-; }

for case_name in "${CASE_LIST[@]}"; do
    CASE_SRC="${ALL_CASES_DIR}/${case_name}"
    [[ -d "${CASE_SRC}" ]] || { echo "ERROR: Case directory not found: ${CASE_SRC}"; exit 1; }

    INPUT_FILE="${CASE_SRC}/input.yaml"
    [[ -f "${INPUT_FILE}" ]] || { echo "ERROR: input.yaml not found in ${CASE_SRC}"; exit 1; }

    JIRA_ISSUE_KEY=$(yaml_val jira_key "${INPUT_FILE}")
    BASE_BRANCH=$(yaml_val base_branch "${INPUT_FILE}")
    EXPECTED_BRANCH=$(yaml_val expected_branch "${INPUT_FILE}")

    CASE_SHARED="${SHARED_DIR}/cases/${case_name}"
    mkdir -p "${CASE_SHARED}"

    echo "${JIRA_ISSUE_KEY}" > "${CASE_SHARED}/jira-issue-key"
    cp "${CASE_SRC}/jira-issue.json" "${CASE_SHARED}/jira-issue.json"
    echo "${BASE_BRANCH}" > "${CASE_SHARED}/eval-base-branch"
    echo "${EXPECTED_BRANCH}" > "${CASE_SHARED}/eval-expected-branch"
    echo "${case_name}" > "${CASE_SHARED}/eval-case"

    SUMMARY=$(jq -r '.fields.summary // .summary // "N/A"' "${CASE_SHARED}/jira-issue.json")
    echo "  ${case_name}: ${JIRA_ISSUE_KEY} - ${SUMMARY}"
done

# --- Write case list for downstream steps ---
printf '%s\n' "${CASE_LIST[@]}" > "${SHARED_DIR}/eval-cases"

echo "=== TRT Eval Init Complete ==="
