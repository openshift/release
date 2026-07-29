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
set +x
CLONE_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
git clone "https://x-access-token:${CLONE_TOKEN}@github.com/${UPSTREAM_REPO}.git" "${TEMPLATE_DIR}"
git -C "${TEMPLATE_DIR}" remote set-url origin "https://github.com/${UPSTREAM_REPO}.git"

GITHUB_TOKEN="${CLONE_TOKEN}"
export GITHUB_TOKEN

# --- Utilities ---
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
ALL_HTML_SECTIONS=""
ALL_YAML_CASES=""

# =============================================
# JUDGE EACH CASE
# =============================================
for case_name in "${CASE_LIST[@]}"; do
    echo ""
    echo "=========================================="
    echo "Judging: ${case_name}"
    echo "=========================================="

    CASE_SHARED="${SHARED_DIR}/cases/${case_name}"

    EVAL_CASE=$(cat "${CASE_SHARED}/eval-case")
    BASE_BRANCH=$(cat "${CASE_SHARED}/eval-base-branch")
    EXPECTED_BRANCH=$(cat "${CASE_SHARED}/eval-expected-branch")
    JIRA_ISSUE_KEY=$(cat "${CASE_SHARED}/jira-issue-key")

    echo "  JIRA: ${JIRA_ISSUE_KEY} | Base: ${BASE_BRANCH} | Expected: ${EXPECTED_BRANCH}"

    # Set up per-case workspace from template
    CASE_WORKDIR="/workspace/${case_name}"
    cp -r "${TEMPLATE_DIR}" "${CASE_WORKDIR}"
    cd "${CASE_WORKDIR}"

    # Check out Claude's branch
    CLAUDE_BRANCH=""
    if [[ -f "${CASE_SHARED}/claude-branch" ]]; then
        CLAUDE_BRANCH=$(cat "${CASE_SHARED}/claude-branch")
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
    echo "  Running: make build..."
    if make build > /tmp/eval-build.log 2>&1; then
        record_check "code_compiles" "pass"
    else
        record_check "code_compiles" "fail"
        echo "  Build output (last 20 lines):"
        tail -20 /tmp/eval-build.log | sed 's/^/    /'
    fi

    # tests_pass
    echo "  Running: make test..."
    if make test > /tmp/eval-test.log 2>&1; then
        record_check "tests_pass" "pass"
    else
        record_check "tests_pass" "fail"
        echo "  Test output (last 20 lines):"
        tail -20 /tmp/eval-test.log | sed 's/^/    /'
    fi

    # pr_created
    PR_NUM=""
    if [[ -f "${CASE_SHARED}/pr-number" ]]; then
        PR_NUM=$(cat "${CASE_SHARED}/pr-number")
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
    if [[ -s "${CASE_SHARED}/pr-description.md" ]]; then
        record_check "pr_description_exists" "pass"
    else
        record_check "pr_description_exists" "fail"
    fi

    # --- Diff-based scoring ---
    echo "  --- Scores ---"

    CLAUDE_FILES=$(git diff "origin/${BASE_BRANCH}" --name-only 2>/dev/null | sort)
    EXPECTED_FILES=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" --name-only 2>/dev/null | sort)

    echo "${CLAUDE_FILES}" > /tmp/eval-claude-files.txt
    echo "${EXPECTED_FILES}" > /tmp/eval-expected-files.txt
    if [[ -n "${CLAUDE_FILES}" || -n "${EXPECTED_FILES}" ]]; then
        OVERLAP=$(jaccard_similarity /tmp/eval-claude-files.txt /tmp/eval-expected-files.txt)
        record_score "file_overlap" "${OVERLAP}"
    else
        OVERLAP="0.0"
        record_score "file_overlap" "0.0"
    fi

    CLAUDE_LINES=$(git diff "origin/${BASE_BRANCH}" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
    CLAUDE_DEL=$(git diff "origin/${BASE_BRANCH}" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
    CLAUDE_TOTAL=$(( CLAUDE_LINES + CLAUDE_DEL ))

    EXPECTED_LINES=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
    EXPECTED_DEL=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
    EXPECTED_TOTAL=$(( EXPECTED_LINES + EXPECTED_DEL ))

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

    # --- Per-case summary ---
    echo "  Checks: ${CHECKS_PASS}/${CHECKS_TOTAL} passed"

    # --- Accumulate aggregates ---
    TOTAL_CHECKS_PASS=$(( TOTAL_CHECKS_PASS + CHECKS_PASS ))
    TOTAL_CHECKS_TOTAL=$(( TOTAL_CHECKS_TOTAL + CHECKS_TOTAL ))

    # JUnit test cases
    for check_name in branch_created code_compiles tests_pass pr_created pr_description_exists; do
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

    # YAML case block
    if [[ -n "${CLAUDE_FILES}" ]]; then
        CLAUDE_FILES_YAML=$(echo "${CLAUDE_FILES}" | sed 's/^/      - /')
    else
        CLAUDE_FILES_YAML="      - (none)"
    fi
    if [[ -n "${EXPECTED_FILES}" ]]; then
        EXPECTED_FILES_YAML=$(echo "${EXPECTED_FILES}" | sed 's/^/      - /')
    else
        EXPECTED_FILES_YAML="      - (none)"
    fi

    ALL_YAML_CASES="${ALL_YAML_CASES}
  - case: ${EVAL_CASE}
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
      passed: ${CHECKS_PASS}
      total: ${CHECKS_TOTAL}
    scores:
$(echo -e "${SCORES}" | sed 's/^/      /')
    claude_files_changed:
${CLAUDE_FILES_YAML}
    expected_files_changed:
${EXPECTED_FILES_YAML}
    claude_diff_lines: ${CLAUDE_TOTAL}
    expected_diff_lines: ${EXPECTED_TOTAL}"

    # HTML case section
    CHECKS_HTML=""
    check_icon() { if [[ "$1" == "pass" ]]; then echo "&#x2705;"; else echo "&#x274C;"; fi; }
    for check_name in branch_created code_compiles tests_pass pr_created pr_description_exists; do
        result="${CHECKS[${check_name}]}"
        CHECKS_HTML="${CHECKS_HTML}<tr><td>$(check_icon "${result}")</td><td>${check_name}</td><td>${result}</td></tr>"
    done

    if [[ -n "${CLAUDE_FILES}" ]]; then
        CLAUDE_FILES_HTML=$(echo "${CLAUDE_FILES}" | sed 's/.*/    <li>\&<\/li>/')
    else
        CLAUDE_FILES_HTML="<li>(none)</li>"
    fi
    if [[ -n "${EXPECTED_FILES}" ]]; then
        EXPECTED_FILES_HTML=$(echo "${EXPECTED_FILES}" | sed 's/.*/    <li>\&<\/li>/')
    else
        EXPECTED_FILES_HTML="<li>(none)</li>"
    fi

    ALL_HTML_SECTIONS="${ALL_HTML_SECTIONS}
<div class=\"case\">
<h2>${EVAL_CASE}</h2>
<table class=\"meta\">
  <tr><td>JIRA</td><td><a href=\"https://redhat.atlassian.net/browse/${JIRA_ISSUE_KEY}\">${JIRA_ISSUE_KEY}</a></td></tr>
  <tr><td>Claude branch</td><td>${CLAUDE_BRANCH:-none}</td></tr>
  <tr><td>Base branch</td><td>${BASE_BRANCH}</td></tr>
  <tr><td>Expected branch</td><td>${EXPECTED_BRANCH}</td></tr>
  <tr><td>PR</td><td>${PR_NUM:+#}${PR_NUM:-none}</td></tr>
</table>

<h3>Checks (${CHECKS_PASS}/${CHECKS_TOTAL})</h3>
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
</div>"

done

# =============================================
# AGGREGATE SUMMARY
# =============================================
echo ""
echo "=========================================="
echo "Aggregate: ${TOTAL_CHECKS_PASS}/${TOTAL_CHECKS_TOTAL} checks passed across ${#CASE_LIST[@]} cases"
echo "=========================================="

# --- eval-summary.yaml ---
cat > "${ARTIFACT_DIR}/eval-summary.yaml" <<SUMMARY_EOF
cases_run: ${#CASE_LIST[@]}
total_checks_passed: ${TOTAL_CHECKS_PASS}
total_checks: ${TOTAL_CHECKS_TOTAL}
cases:${ALL_YAML_CASES}
SUMMARY_EOF
echo "Summary written to ${ARTIFACT_DIR}/eval-summary.yaml"

# --- JUnit XML ---
TOTAL_FAILURES=$(( TOTAL_CHECKS_TOTAL - TOTAL_CHECKS_PASS ))
cat > "${ARTIFACT_DIR}/junit_jira-solver-eval.xml" <<JUNIT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="jira-solver-eval" tests="${TOTAL_CHECKS_TOTAL}" failures="${TOTAL_FAILURES}">
${ALL_JUNIT_TESTCASES}
</testsuite>
JUNIT_EOF
echo "JUnit XML written to ${ARTIFACT_DIR}/junit_jira-solver-eval.xml"

# --- HTML ---
cat > "${ARTIFACT_DIR}/eval-summary.html" <<HTML_EOF
<!DOCTYPE html>
<html>
<head>
<title>Jira-Solver Eval Summary</title>
<style>
  body { font-family: -apple-system, sans-serif; max-width: 900px; margin: 2em auto; padding: 0 1em; }
  h1 { font-size: 1.4em; }
  h2 { font-size: 1.2em; margin-top: 2em; border-bottom: 2px solid #333; padding-bottom: 0.3em; }
  h3 { font-size: 1em; margin-top: 1em; border-bottom: 1px solid #ddd; padding-bottom: 0.2em; }
  table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
  th, td { text-align: left; padding: 6px 12px; border: 1px solid #ddd; }
  th { background: #f5f5f5; }
  .score { font-size: 1.3em; font-weight: bold; }
  .meta td:first-child { font-weight: bold; width: 160px; }
  .summary { font-size: 1.2em; margin: 1em 0; padding: 0.5em; background: #f0f0f0; border-radius: 4px; }
  ul { margin: 0.3em 0; padding-left: 1.5em; }
  .case { margin-bottom: 2em; }
</style>
</head>
<body>
<h1>Jira-Solver Eval Results</h1>
<div class="summary">
  ${TOTAL_CHECKS_PASS}/${TOTAL_CHECKS_TOTAL} checks passed across ${#CASE_LIST[@]} cases
</div>
${ALL_HTML_SECTIONS}
</body>
</html>
HTML_EOF
echo "HTML summary written to ${ARTIFACT_DIR}/eval-summary.html"

echo "=== TRT Eval Judge Complete ==="
