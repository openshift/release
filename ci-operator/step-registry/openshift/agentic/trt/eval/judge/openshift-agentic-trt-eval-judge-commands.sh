#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Judge ==="

# --- Read case list ---
mapfile -t CASE_LIST < "${SHARED_DIR}/eval-cases"
echo "Cases to judge (${#CASE_LIST[@]}): ${CASE_LIST[*]}"

# --- Clone repo template ---
TEMPLATE_DIR="/tmp/eval-repo-template"
CLONE_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
git clone "https://x-access-token:${CLONE_TOKEN}@github.com/${UPSTREAM_REPO}.git" "${TEMPLATE_DIR}"
git -C "${TEMPLATE_DIR}" remote set-url origin "https://github.com/${UPSTREAM_REPO}.git"

GITHUB_TOKEN="${CLONE_TOKEN}"
export GITHUB_TOKEN

# --- Utilities ---
diff_stat_total() {
    local stat_line=$1
    local ins del
    ins=$(echo "${stat_line}" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
    del=$(echo "${stat_line}" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
    echo $(( ins + del ))
}

jaccard_similarity() {
    local file_a=$1 file_b=$2
    python3 -c "
import sys
a = set(open(sys.argv[1]).read().strip().split('\n')) if open(sys.argv[1]).read().strip() else set()
b = set(open(sys.argv[2]).read().strip().split('\n')) if open(sys.argv[2]).read().strip() else set()
if not a and not b: print('1.0')
elif not a or not b: print('0.0')
else: print(f'{len(a & b) / len(a | b):.2f}')
" "${file_a}" "${file_b}"
}

# --- Aggregate accumulators ---
TOTAL_CHECKS_PASS=0
TOTAL_CHECKS_TOTAL=0
ALL_JUNIT_TESTCASES=""
ALL_SUMMARY_ROWS=""
ALL_CASE_DETAILS=""

# =============================================
# JUDGE EACH CASE
# =============================================
for case_name in "${CASE_LIST[@]}"; do
    echo ""
    echo "=========================================="
    echo "Judging: ${case_name}"
    echo "=========================================="

    EVAL_CASE=$(cat "${SHARED_DIR}/${case_name}.eval-case")
    BASE_BRANCH=$(cat "${SHARED_DIR}/${case_name}.eval-base-branch")
    EXPECTED_BRANCH=$(cat "${SHARED_DIR}/${case_name}.eval-expected-branch")
    JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/${case_name}.jira-issue-key")

    echo "  JIRA: ${JIRA_ISSUE_KEY} | Base: ${BASE_BRANCH} | Expected: ${EXPECTED_BRANCH}"

    # Set up per-case workspace from template
    CASE_WORKDIR="/workspace/${case_name}"
    cp -r "${TEMPLATE_DIR}" "${CASE_WORKDIR}"
    cd "${CASE_WORKDIR}"

    # Check out Claude's branch
    CLAUDE_BRANCH=""
    if [[ -f "${SHARED_DIR}/${case_name}.claude-branch" ]]; then
        CLAUDE_BRANCH=$(cat "${SHARED_DIR}/${case_name}.claude-branch")
        git fetch origin "${CLAUDE_BRANCH}"
        git checkout "${CLAUDE_BRANCH}"
    fi
    echo "  Claude's branch: ${CLAUDE_BRANCH:-<none>}"

    git fetch origin "${BASE_BRANCH}" "${EXPECTED_BRANCH}" 2>/dev/null || true

    # --- Per-case results ---
    unset CHECKS 2>/dev/null || true
    declare -A CHECKS
    CHECKS_PASS=0
    CHECKS_TOTAL=0
    SCORES=""

    record_check() {
        local name=$1 result=$2
        CHECKS["${name}"]="${result}"
        CHECKS_TOTAL=$(( CHECKS_TOTAL + 1 ))
        if [[ "${result}" == "pass" ]]; then
            CHECKS_PASS=$(( CHECKS_PASS + 1 ))
            echo "  [PASS] ${name}"
        else
            echo "  [FAIL] ${name}"
        fi
    }

    record_score() {
        local name=$1 value=$2
        SCORES="${SCORES}${name}: ${value}\n"
        echo "  [SCORE] ${name}: ${value}"
    }

    # --- Hardcoded checks ---
    echo "  --- Checks ---"

    # branch_created
    if [[ -n "${CLAUDE_BRANCH}" && "${CLAUDE_BRANCH}" != "main" && "${CLAUDE_BRANCH}" != "master" && "${CLAUDE_BRANCH}" != "${BASE_BRANCH}" ]]; then
        record_check "branch_created" "pass"
    else
        record_check "branch_created" "fail"
    fi

    # code_compiles
    BUILD_LOG="${ARTIFACT_DIR}/${case_name}-build.log"
    echo "  Running: make build..."
    if make build > "${BUILD_LOG}" 2>&1; then
        record_check "code_compiles" "pass"
    else
        record_check "code_compiles" "fail"
        echo "  Build output (last 20 lines):"
        tail -20 "${BUILD_LOG}" | sed 's/^/    /'
    fi

    # tests_pass
    TEST_LOG="${ARTIFACT_DIR}/${case_name}-test.log"
    echo "  Running: make test..."
    if make test > "${TEST_LOG}" 2>&1; then
        record_check "tests_pass" "pass"
    else
        record_check "tests_pass" "fail"
        echo "  Test output (last 20 lines):"
        tail -20 "${TEST_LOG}" | sed 's/^/    /'
    fi

    # pr_created
    PR_NUM=""
    if [[ -f "${SHARED_DIR}/${case_name}.pr-number" ]]; then
        PR_NUM=$(cat "${SHARED_DIR}/${case_name}.pr-number")
    fi
    if [[ -n "${PR_NUM}" ]]; then
        record_check "pr_created" "pass"
        echo "  PR #${PR_NUM}"
    else
        PR_SEARCH=$(gh pr list --repo "${UPSTREAM_REPO}" --state open --search "${JIRA_ISSUE_KEY}" --json number --limit 1 2>/dev/null || echo "[]")
        PR_NUM=$(echo "${PR_SEARCH}" | jq -r '.[0].number // empty' 2>/dev/null || echo "")
        if [[ -n "${PR_NUM}" ]]; then
            record_check "pr_created" "pass"
            echo "  Found PR #${PR_NUM}"
        else
            record_check "pr_created" "fail"
        fi
    fi

    # pr_description_exists
    if [[ -s "${SHARED_DIR}/${case_name}.pr-description.md" ]]; then
        record_check "pr_description_exists" "pass"
    else
        record_check "pr_description_exists" "fail"
    fi

    # --- Diff-based scoring ---
    echo "  --- Scores ---"

    CLAUDE_FILES=$(git diff "origin/${BASE_BRANCH}" --name-only 2>/dev/null | sort || echo "")
    EXPECTED_FILES=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" --name-only 2>/dev/null | sort || echo "")

    echo "${CLAUDE_FILES}" > /tmp/eval-claude-files.txt
    echo "${EXPECTED_FILES}" > /tmp/eval-expected-files.txt
    if [[ -n "${CLAUDE_FILES}" || -n "${EXPECTED_FILES}" ]]; then
        OVERLAP=$(jaccard_similarity /tmp/eval-claude-files.txt /tmp/eval-expected-files.txt)
        record_score "file_overlap" "${OVERLAP}"
    else
        OVERLAP="0.0"
        record_score "file_overlap" "0.0"
    fi

    CLAUDE_STAT=$(git diff "origin/${BASE_BRANCH}" --stat 2>/dev/null | tail -1 || echo "")
    CLAUDE_TOTAL=$(diff_stat_total "${CLAUDE_STAT}")

    EXPECTED_STAT=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" --stat 2>/dev/null | tail -1 || echo "")
    EXPECTED_TOTAL=$(diff_stat_total "${EXPECTED_STAT}")

    if [[ "${EXPECTED_TOTAL}" -gt 0 ]]; then
        RATIO=$(python3 -c "print(f'{${CLAUDE_TOTAL} / ${EXPECTED_TOTAL}:.2f}')")
        record_score "diff_size_ratio" "${RATIO}"
    else
        RATIO="N/A"
        record_score "diff_size_ratio" "N/A"
    fi

    CLAUDE_FUNCS=$(git diff "origin/${BASE_BRANCH}" -U0 2>/dev/null | grep -E '^\+.*func |^\+.*def |^\+.*function |^@@.*@@.*func |^@@.*@@.*def |^@@.*@@.*function ' | sed 's/.*func /func /;s/.*def /def /;s/.*function /function /' | sort -u || echo "")
    EXPECTED_FUNCS=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" -U0 2>/dev/null | grep -E '^\+.*func |^\+.*def |^\+.*function |^@@.*@@.*func |^@@.*@@.*def |^@@.*@@.*function ' | sed 's/.*func /func /;s/.*def /def /;s/.*function /function /' | sort -u || echo "")

    echo "${CLAUDE_FUNCS}" > /tmp/eval-claude-funcs.txt
    echo "${EXPECTED_FUNCS}" > /tmp/eval-expected-funcs.txt
    if [[ -n "${CLAUDE_FUNCS}" || -n "${EXPECTED_FUNCS}" ]]; then
        FUNC_OVERLAP=$(jaccard_similarity /tmp/eval-claude-funcs.txt /tmp/eval-expected-funcs.txt)
        record_score "function_overlap" "${FUNC_OVERLAP}"
    else
        FUNC_OVERLAP="N/A"
        record_score "function_overlap" "N/A"
    fi

    # --- Score-based checks ---
    if python3 -c "exit(0 if float('${OVERLAP}') >= 0.25 else 1)" 2>/dev/null; then
        record_check "file_overlap_threshold" "pass"
    else
        record_check "file_overlap_threshold" "fail"
    fi

    if [[ "${RATIO}" == "N/A" ]]; then
        record_check "diff_size_threshold" "pass"
    elif python3 -c "r=float('${RATIO}'); exit(0 if 0.1 <= r <= 5.0 else 1)" 2>/dev/null; then
        record_check "diff_size_threshold" "pass"
    else
        record_check "diff_size_threshold" "fail"
    fi

    # --- Per-case summary ---
    echo "  Checks: ${CHECKS_PASS}/${CHECKS_TOTAL} passed"

    # --- Accumulate aggregates ---
    TOTAL_CHECKS_PASS=$(( TOTAL_CHECKS_PASS + CHECKS_PASS ))
    TOTAL_CHECKS_TOTAL=$(( TOTAL_CHECKS_TOTAL + CHECKS_TOTAL ))

    # JUnit test cases
    for check_name in branch_created code_compiles tests_pass pr_created pr_description_exists file_overlap_threshold diff_size_threshold; do
        result="${CHECKS[${check_name}]}"
        if [[ "${result}" == "pass" ]]; then
            ALL_JUNIT_TESTCASES="${ALL_JUNIT_TESTCASES}
  <testcase name=\"[jira-solver-eval] ${EVAL_CASE} ${check_name}\" classname=\"jira-solver-eval.${EVAL_CASE}\"/>"
        else
            ALL_JUNIT_TESTCASES="${ALL_JUNIT_TESTCASES}
  <testcase name=\"[jira-solver-eval] ${EVAL_CASE} ${check_name}\" classname=\"jira-solver-eval.${EVAL_CASE}\">
    <failure message=\"${check_name} failed\">${check_name} check did not pass.</failure>
  </testcase>"
        fi
    done

    # --- Per-case YAML ---
    if [[ -n "${CLAUDE_FILES}" ]]; then
        CLAUDE_FILES_YAML=$(echo "${CLAUDE_FILES}" | sed 's/^/  - /')
    else
        CLAUDE_FILES_YAML="  - (none)"
    fi
    if [[ -n "${EXPECTED_FILES}" ]]; then
        EXPECTED_FILES_YAML=$(echo "${EXPECTED_FILES}" | sed 's/^/  - /')
    else
        EXPECTED_FILES_YAML="  - (none)"
    fi

    cat > "${ARTIFACT_DIR}/eval-${EVAL_CASE}.yaml" <<CASE_YAML_EOF
case: ${EVAL_CASE}
jira_key: ${JIRA_ISSUE_KEY}
claude_branch: ${CLAUDE_BRANCH:-none}
base_branch: ${BASE_BRANCH}
expected_branch: ${EXPECTED_BRANCH}
pr_number: ${PR_NUM:-none}
checks:
  branch_created: ${CHECKS[branch_created]}
  code_compiles: ${CHECKS[code_compiles]}
  tests_pass: ${CHECKS[tests_pass]}
  pr_created: ${CHECKS[pr_created]}
  pr_description_exists: ${CHECKS[pr_description_exists]}
  file_overlap_threshold: ${CHECKS[file_overlap_threshold]}
  diff_size_threshold: ${CHECKS[diff_size_threshold]}
  passed: ${CHECKS_PASS}
  total: ${CHECKS_TOTAL}
scores:
$(echo -e "${SCORES}" | sed 's/^/  /')
claude_files_changed:
${CLAUDE_FILES_YAML}
expected_files_changed:
${EXPECTED_FILES_YAML}
claude_diff_lines: ${CLAUDE_TOTAL}
expected_diff_lines: ${EXPECTED_TOTAL}
CASE_YAML_EOF
    echo "  Written: eval-${EVAL_CASE}.yaml"

    # --- Build link strings ---
    EXPECTED_DIFF_URL="https://github.com/${UPSTREAM_REPO}/compare/${BASE_BRANCH}...${EXPECTED_BRANCH}"
    if [[ -n "${PR_NUM}" ]]; then
        PR_LINK_HTML="<a href=\"https://github.com/${UPSTREAM_REPO}/pull/${PR_NUM}\">#${PR_NUM}</a>"
    else
        PR_LINK_HTML="none"
    fi

    # --- Per-case HTML detail (inline into summary) ---
    CHECKS_HTML=""
    check_icon() { if [[ "$1" == "pass" ]]; then echo "&#x2705;"; else echo "&#x274C;"; fi; }
    for check_name in branch_created code_compiles tests_pass pr_created pr_description_exists file_overlap_threshold diff_size_threshold; do
        result="${CHECKS[${check_name}]}"
        CHECKS_HTML="${CHECKS_HTML}<tr><td>$(check_icon "${result}")</td><td>${check_name}</td><td>${result}</td></tr>"
    done

    if [[ -n "${CLAUDE_FILES}" ]]; then
        CLAUDE_FILES_HTML=$(echo "${CLAUDE_FILES}" | while IFS= read -r f; do echo "<li>${f}</li>"; done)
    else
        CLAUDE_FILES_HTML="<li>(none)</li>"
    fi
    if [[ -n "${EXPECTED_FILES}" ]]; then
        EXPECTED_FILES_HTML=$(echo "${EXPECTED_FILES}" | while IFS= read -r f; do echo "<li>${f}</li>"; done)
    else
        EXPECTED_FILES_HTML="<li>(none)</li>"
    fi

    ALL_CASE_DETAILS="${ALL_CASE_DETAILS}
<details>
<summary><strong>${EVAL_CASE}</strong> — ${JIRA_ISSUE_KEY} — ${CHECKS_PASS}/${CHECKS_TOTAL} checks</summary>
<div class=\"case-detail\">
<table class=\"meta\">
  <tr><td>JIRA</td><td><a href=\"https://redhat.atlassian.net/browse/${JIRA_ISSUE_KEY}\">${JIRA_ISSUE_KEY}</a></td></tr>
  <tr><td>Claude branch</td><td>${CLAUDE_BRANCH:-none}</td></tr>
  <tr><td>Base branch</td><td>${BASE_BRANCH}</td></tr>
  <tr><td>Expected branch</td><td>${EXPECTED_BRANCH}</td></tr>
  <tr><td>PR</td><td>${PR_LINK_HTML}</td></tr>
  <tr><td>Expected diff</td><td><a href=\"${EXPECTED_DIFF_URL}\">view</a></td></tr>
</table>
<h3>Checks</h3>
<table>
  <tr><th></th><th>Check</th><th>Result</th></tr>
  ${CHECKS_HTML}
</table>
<h3>Scores</h3>
<table>
  <tr><th>Metric</th><th>Value</th></tr>
  <tr><td>File overlap (Jaccard)</td><td class=\"score\">${OVERLAP:-N/A}</td></tr>
  <tr><td>Diff size ratio (claude/expected)</td><td class=\"score\">${RATIO:-N/A}</td></tr>
  <tr><td>Function overlap</td><td class=\"score\">${FUNC_OVERLAP:-N/A}</td></tr>
</table>
<h3>Files Changed</h3>
<table>
  <tr><th>Claude (${CLAUDE_TOTAL} lines)</th><th>Expected (${EXPECTED_TOTAL} lines)</th></tr>
  <tr>
    <td><ul>${CLAUDE_FILES_HTML}</ul></td>
    <td><ul>${EXPECTED_FILES_HTML}</ul></td>
  </tr>
</table>
</div>
</details>"

    # --- Accumulate summary table row ---
    ALL_SUMMARY_ROWS="${ALL_SUMMARY_ROWS}<tr><td>${EVAL_CASE}</td><td>${JIRA_ISSUE_KEY}</td><td>${CHECKS_PASS}/${CHECKS_TOTAL}</td><td>${OVERLAP:-N/A}</td><td>${RATIO:-N/A}</td><td>${FUNC_OVERLAP:-N/A}</td><td>${PR_LINK_HTML}</td><td><a href=\"${EXPECTED_DIFF_URL}\">diff</a></td></tr>"

done

# =============================================
# AGGREGATE SUMMARY
# =============================================
echo ""
echo "=========================================="
echo "Aggregate: ${TOTAL_CHECKS_PASS}/${TOTAL_CHECKS_TOTAL} checks passed across ${#CASE_LIST[@]} cases"
echo "=========================================="

# --- JUnit XML ---
TOTAL_FAILURES=$(( TOTAL_CHECKS_TOTAL - TOTAL_CHECKS_PASS ))
cat > "${ARTIFACT_DIR}/junit_jira-solver-eval.xml" <<JUNIT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="jira-solver-eval" tests="${TOTAL_CHECKS_TOTAL}" failures="${TOTAL_FAILURES}">
${ALL_JUNIT_TESTCASES}
</testsuite>
JUNIT_EOF
echo "JUnit XML written to ${ARTIFACT_DIR}/junit_jira-solver-eval.xml"

# --- Summary YAML ---
cat > "${ARTIFACT_DIR}/eval-summary.yaml" <<SUMMARY_EOF
cases_run: ${#CASE_LIST[@]}
total_checks_passed: ${TOTAL_CHECKS_PASS}
total_checks: ${TOTAL_CHECKS_TOTAL}
SUMMARY_EOF
echo "Summary written to ${ARTIFACT_DIR}/eval-summary.yaml"

# --- Summary HTML (single file with inline per-case details) ---
cat > "${ARTIFACT_DIR}/eval-summary.html" <<HTML_EOF
<!DOCTYPE html>
<html>
<head>
<title>Jira-Solver Eval Summary</title>
<style>
  body { font-family: -apple-system, sans-serif; max-width: 900px; margin: 2em auto; padding: 0 1em 3em; }
  h1 { font-size: 1.4em; }
  h2 { font-size: 1.1em; margin-top: 1.5em; }
  h3 { font-size: 0.95em; margin-top: 1em; }
  table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
  th, td { text-align: left; padding: 6px 12px; border: 1px solid #ddd; }
  th { background: #f5f5f5; }
  .summary { font-size: 1.2em; margin: 1em 0; padding: 0.5em; background: #f0f0f0; border-radius: 4px; }
  .score { font-size: 1.1em; font-weight: bold; }
  .meta td:first-child { font-weight: bold; width: 160px; }
  ul { margin: 0.3em 0; padding-left: 1.5em; }
  details { margin: 0.5em 0 1em; border: 1px solid #ddd; border-radius: 4px; }
  summary { padding: 8px 12px; cursor: pointer; background: #fafafa; }
  summary:hover { background: #f0f0f0; }
  .case-detail { padding: 0 16px 12px; }
</style>
</head>
<body>
<h1>Jira-Solver Eval Results</h1>
<div class="summary">
  ${TOTAL_CHECKS_PASS}/${TOTAL_CHECKS_TOTAL} checks passed across ${#CASE_LIST[@]} cases
</div>

<h2>Overview</h2>
<table>
  <tr><th>Case</th><th>JIRA</th><th>Checks</th><th>File Overlap</th><th>Diff Ratio</th><th>Func Overlap</th><th>PR</th><th>Expected</th></tr>
  ${ALL_SUMMARY_ROWS}
</table>

<h2>Case Details</h2>
${ALL_CASE_DETAILS}
</body>
</html>
HTML_EOF
echo "HTML summary written to ${ARTIFACT_DIR}/eval-summary.html"

if [[ "${TOTAL_CHECKS_PASS}" -lt "${TOTAL_CHECKS_TOTAL}" ]]; then
    echo "FAILED: ${TOTAL_CHECKS_PASS}/${TOTAL_CHECKS_TOTAL} checks passed."
    exit 1
fi

echo "=== TRT Eval Judge Complete ==="
