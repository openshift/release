#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Judge ==="

# --- Read eval metadata from SHARED_DIR ---
EVAL_CASE=$(cat "${SHARED_DIR}/eval-case")
BASE_BRANCH=$(cat "${SHARED_DIR}/eval-base-branch")
EXPECTED_BRANCH=$(cat "${SHARED_DIR}/eval-expected-branch")
JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/jira-issue-key")

echo "Case: ${EVAL_CASE}"
echo "Base branch: ${BASE_BRANCH}"
echo "Expected branch: ${EXPECTED_BRANCH}"
echo "JIRA: ${JIRA_ISSUE_KEY}"

# --- Set up workspace ---
cd /workspace
if [[ ! -d .git ]]; then
    set +x
    CLONE_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
    git clone "https://x-access-token:${CLONE_TOKEN}@github.com/${UPSTREAM_REPO}.git" /tmp/eval-repo
    cp -r /tmp/eval-repo/. /workspace/
    rm -rf /tmp/eval-repo
    git remote set-url origin "https://github.com/${UPSTREAM_REPO}.git"
fi

# --- Check out Claude's branch ---
CLAUDE_BRANCH=""
if [[ -f "${SHARED_DIR}/claude-branch" ]]; then
    CLAUDE_BRANCH=$(cat "${SHARED_DIR}/claude-branch")
    git fetch origin "${CLAUDE_BRANCH}"
    git checkout "${CLAUDE_BRANCH}"
fi
echo "Claude's branch: ${CLAUDE_BRANCH:-<none>}"

# --- Fetch base and expected branches for comparison ---
git fetch origin "${BASE_BRANCH}" "${EXPECTED_BRANCH}" 2>/dev/null || true

# --- Initialize results ---
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

# =============================================
# HARDCODED CHECKS
# =============================================
echo ""
echo "--- Hardcoded Checks ---"

# 1. branch_created
if [[ -n "${CLAUDE_BRANCH}" && "${CLAUDE_BRANCH}" != "main" && "${CLAUDE_BRANCH}" != "master" && "${CLAUDE_BRANCH}" != "${BASE_BRANCH}" ]]; then
    record_check "branch_created" "pass"
else
    record_check "branch_created" "fail"
fi

# 2. code_compiles
echo "  Running: make build..."
if make build > /tmp/eval-build.log 2>&1; then
    record_check "code_compiles" "pass"
else
    record_check "code_compiles" "fail"
    echo "  Build output (last 20 lines):"
    tail -20 /tmp/eval-build.log | sed 's/^/    /'
fi

# 3. tests_pass
echo "  Running: make test..."
if make test > /tmp/eval-test.log 2>&1; then
    record_check "tests_pass" "pass"
else
    record_check "tests_pass" "fail"
    echo "  Test output (last 20 lines):"
    tail -20 /tmp/eval-test.log | sed 's/^/    /'
fi

# 4. pr_created
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token" 2>/dev/null || echo "")
export GITHUB_TOKEN

PR_NUM=""
if [[ -f "${SHARED_DIR}/pr-number" ]]; then
    PR_NUM=$(cat "${SHARED_DIR}/pr-number")
fi
if [[ -n "${PR_NUM}" ]]; then
    record_check "pr_created" "pass"
    echo "  PR #${PR_NUM}"
else
    if [[ -n "${GITHUB_TOKEN}" ]]; then
        PR_SEARCH=$(gh pr list --repo "${UPSTREAM_REPO}" --state open --search "${JIRA_ISSUE_KEY}" --json number --limit 1 2>/dev/null || echo "[]")
        PR_NUM=$(echo "${PR_SEARCH}" | jq -r '.[0].number // empty' 2>/dev/null || echo "")
    fi
    if [[ -n "${PR_NUM}" ]]; then
        record_check "pr_created" "pass"
        echo "  Found PR #${PR_NUM}"
    else
        record_check "pr_created" "fail"
    fi
fi

# 5. pr_description_exists
if [[ -s "${SHARED_DIR}/pr-description.md" ]]; then
    record_check "pr_description_exists" "pass"
else
    record_check "pr_description_exists" "fail"
fi

# =============================================
# DIFF-BASED SCORING
# =============================================
echo ""
echo "--- Diff-Based Scoring ---"

# Get files changed by Claude vs expected
CLAUDE_FILES=$(git diff "origin/${BASE_BRANCH}" --name-only 2>/dev/null | sort)
EXPECTED_FILES=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" --name-only 2>/dev/null | sort)

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

# file_overlap: Jaccard similarity
echo "${CLAUDE_FILES}" > /tmp/eval-claude-files.txt
echo "${EXPECTED_FILES}" > /tmp/eval-expected-files.txt
if [[ -n "${CLAUDE_FILES}" || -n "${EXPECTED_FILES}" ]]; then
    OVERLAP=$(jaccard_similarity /tmp/eval-claude-files.txt /tmp/eval-expected-files.txt)
    record_score "file_overlap" "${OVERLAP}"
else
    record_score "file_overlap" "0.0"
fi

# diff_size_ratio
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
    record_score "diff_size_ratio" "N/A"
fi

# function_overlap: compare modified functions/methods
CLAUDE_FUNCS=$(git diff "origin/${BASE_BRANCH}" -U0 2>/dev/null | grep -E '^\+.*func |^\+.*def |^\+.*function |^@@.*@@.*func |^@@.*@@.*def |^@@.*@@.*function ' | sed 's/.*func /func /;s/.*def /def /;s/.*function /function /' | sort -u || echo "")
EXPECTED_FUNCS=$(git diff "origin/${BASE_BRANCH}" "origin/${EXPECTED_BRANCH}" -U0 2>/dev/null | grep -E '^\+.*func |^\+.*def |^\+.*function |^@@.*@@.*func |^@@.*@@.*def |^@@.*@@.*function ' | sed 's/.*func /func /;s/.*def /def /;s/.*function /function /' | sort -u || echo "")

echo "${CLAUDE_FUNCS}" > /tmp/eval-claude-funcs.txt
echo "${EXPECTED_FUNCS}" > /tmp/eval-expected-funcs.txt
if [[ -n "${CLAUDE_FUNCS}" || -n "${EXPECTED_FUNCS}" ]]; then
    FUNC_OVERLAP=$(jaccard_similarity /tmp/eval-claude-funcs.txt /tmp/eval-expected-funcs.txt)
    record_score "function_overlap" "${FUNC_OVERLAP}"
else
    record_score "function_overlap" "N/A"
fi

# =============================================
# SUMMARY
# =============================================
echo ""
echo "--- Summary ---"
echo "Checks: ${CHECKS_PASS}/${CHECKS_TOTAL} passed"

# Print file comparison
echo ""
echo "Files changed by Claude:"
if [[ -n "${CLAUDE_FILES}" ]]; then echo "${CLAUDE_FILES}" | sed 's/^/  /'; else echo "  (none)"; fi
echo "Files changed (expected):"
if [[ -n "${EXPECTED_FILES}" ]]; then echo "${EXPECTED_FILES}" | sed 's/^/  /'; else echo "  (none)"; fi

# =============================================
# OUTPUT: eval-summary.yaml
# =============================================
SUMMARY_FILE="${ARTIFACT_DIR}/eval-summary.yaml"
cat > "${SUMMARY_FILE}" <<SUMMARY_EOF
eval_case: ${EVAL_CASE}
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
$(echo -e "${SCORES}" | sed 's/^/  /')
claude_files_changed:
$(echo "${CLAUDE_FILES}" | sed 's/^/  - /')
expected_files_changed:
$(echo "${EXPECTED_FILES}" | sed 's/^/  - /')
claude_diff_lines: ${CLAUDE_TOTAL}
expected_diff_lines: ${EXPECTED_TOTAL}
SUMMARY_EOF

echo "Summary written to ${SUMMARY_FILE}"

# =============================================
# OUTPUT: JUnit XML
# =============================================
JUNIT_FILE="${ARTIFACT_DIR}/junit_jira-solver-eval.xml"
FAILURES=$(( CHECKS_TOTAL - CHECKS_PASS ))

TESTCASES=""
for check_name in branch_created code_compiles tests_pass pr_created pr_description_exists; do
    result="${CHECKS[${check_name}]}"
    if [[ "${result}" == "pass" ]]; then
        TESTCASES="${TESTCASES}
  <testcase name=\"[jira-solver-eval] ${EVAL_CASE} ${check_name}\" classname=\"jira-solver-eval.${EVAL_CASE}\"/>"
    else
        TESTCASES="${TESTCASES}
  <testcase name=\"[jira-solver-eval] ${EVAL_CASE} ${check_name}\" classname=\"jira-solver-eval.${EVAL_CASE}\">
    <failure message=\"${check_name} failed\">${check_name} check did not pass.</failure>
  </testcase>"
    fi
done

cat > "${JUNIT_FILE}" <<JUNIT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="jira-solver-eval" tests="${CHECKS_TOTAL}" failures="${FAILURES}">
${TESTCASES}
</testsuite>
JUNIT_EOF

echo "JUnit XML written to ${JUNIT_FILE}"

# =============================================
# OUTPUT: HTML Summary
# =============================================
HTML_FILE="${ARTIFACT_DIR}/eval-summary.html"

check_icon() {
    if [[ "$1" == "pass" ]]; then echo "&#x2705;"; else echo "&#x274C;"; fi
}

CHECKS_HTML=""
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

cat > "${HTML_FILE}" <<HTML_EOF
<!DOCTYPE html>
<html>
<head>
<title>Eval: ${EVAL_CASE}</title>
<style>
  body { font-family: -apple-system, sans-serif; max-width: 900px; margin: 2em auto; padding: 0 1em; }
  h1 { font-size: 1.4em; }
  h2 { font-size: 1.1em; margin-top: 1.5em; border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
  table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
  th, td { text-align: left; padding: 6px 12px; border: 1px solid #ddd; }
  th { background: #f5f5f5; }
  .score { font-size: 1.3em; font-weight: bold; }
  .meta td:first-child { font-weight: bold; width: 160px; }
  ul { margin: 0.3em 0; padding-left: 1.5em; }
  .pass { color: #1a7f37; } .fail { color: #cf222e; }
</style>
</head>
<body>
<h1>Jira-Solver Eval: ${EVAL_CASE}</h1>

<h2>Metadata</h2>
<table class="meta">
  <tr><td>JIRA</td><td><a href="https://redhat.atlassian.net/browse/${JIRA_ISSUE_KEY}">${JIRA_ISSUE_KEY}</a></td></tr>
  <tr><td>Claude branch</td><td>${CLAUDE_BRANCH:-none}</td></tr>
  <tr><td>Base branch</td><td>${BASE_BRANCH}</td></tr>
  <tr><td>Expected branch</td><td>${EXPECTED_BRANCH}</td></tr>
  <tr><td>PR</td><td>${PR_NUM:+#}${PR_NUM:-none}</td></tr>
</table>

<h2>Checks (${CHECKS_PASS}/${CHECKS_TOTAL})</h2>
<table>
  <tr><th></th><th>Check</th><th>Result</th></tr>
  ${CHECKS_HTML}
</table>

<h2>Scores</h2>
<table>
  <tr><th>Metric</th><th>Value</th></tr>
  <tr><td>File overlap (Jaccard)</td><td class="score">${OVERLAP:-N/A}</td></tr>
  <tr><td>Diff size ratio (claude/expected)</td><td class="score">${RATIO:-N/A}</td></tr>
  <tr><td>Function overlap</td><td class="score">${FUNC_OVERLAP:-N/A}</td></tr>
</table>

<h2>Files Changed</h2>
<table>
  <tr><th>Claude (${CLAUDE_TOTAL} lines)</th><th>Expected (${EXPECTED_TOTAL} lines)</th></tr>
  <tr>
    <td><ul>${CLAUDE_FILES_HTML}</ul></td>
    <td><ul>${EXPECTED_FILES_HTML}</ul></td>
  </tr>
</table>
</body>
</html>
HTML_EOF

echo "HTML summary written to ${HTML_FILE}"

echo "=== TRT Eval Judge Complete ==="
