#!/bin/bash
set -euo pipefail

echo "=== Agentic QE Report Generation ==="

REPORT_FILE="${ARTIFACT_DIR}/agentic-qe-report.html"
RUN_TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

format_number() {
  printf "%s" "$1" | sed -e ':a' -e 's/\([0-9]\)\([0-9]\{3\}\)\(\b\)/\1,\2\3/' -e 'ta'
}

format_cost() {
  printf '$%.4f' "${1:-0}"
}

format_duration() {
  local secs=$1
  if [ "$secs" -eq 0 ] 2>/dev/null; then echo "-"; return; fi
  local hours=$((secs / 3600))
  local mins=$(( (secs % 3600) / 60 ))
  local s=$((secs % 60))
  if [ "$hours" -gt 0 ]; then printf "%dh %dm %ds" "$hours" "$mins" "$s"
  elif [ "$mins" -gt 0 ]; then printf "%dm %ds" "$mins" "$s"
  else printf "%ds" "$s"; fi
}

html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

read_file() {
  local file=$1
  if [ -f "$file" ] && [ -s "$file" ]; then cat "$file"; else echo "(none)"; fi
}

read_token_field() {
  local file=$1 field=$2
  if [ -f "$file" ]; then jq -r ".${field} // 0" "$file" 2>/dev/null || echo "0"; else echo "0"; fi
}

# Find extracted token files from SHARED_DIR
TOKEN_FILES=$(find "${SHARED_DIR}" -name 'claude-*-tokens.json' 2>/dev/null | sort || true)

if [ -z "$TOKEN_FILES" ]; then
  echo "No Claude output files found. Nothing to report."
  cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html><head><title>Agentic QE Report</title></head>
<body><h1>Agentic QE Report</h1><p>No test plans were executed.</p></body></html>
EOF
  exit 0
fi

TOTAL=0
PASS_COUNT=0
FAIL_COUNT=0
GRAND_TOTAL_INPUT=0
GRAND_TOTAL_OUTPUT=0
GRAND_TOTAL_CACHE_READ=0
GRAND_TOTAL_CACHE_CREATE=0
GRAND_TOTAL_COST_USD="0"
SUMMARY_ROWS=""
DETAIL_SECTIONS=""

for TOKEN_FILE in $TOKEN_FILES; do
  PLAN_BASENAME=$(basename "$TOKEN_FILE" | sed 's/^claude-//; s/-tokens\.json$//')
  TOTAL=$((TOTAL + 1))

  echo "Processing test plan: $PLAN_BASENAME"

  # Read token metrics
  P_INPUT=$(read_token_field "$TOKEN_FILE" "input_tokens")
  P_OUTPUT=$(read_token_field "$TOKEN_FILE" "output_tokens")
  P_CACHE_READ=$(read_token_field "$TOKEN_FILE" "cache_read_input_tokens")
  P_CACHE_CREATE=$(read_token_field "$TOKEN_FILE" "cache_creation_input_tokens")
  P_COST_RAW=$(read_token_field "$TOKEN_FILE" "total_cost_usd")
  P_DURATION_MS=$(read_token_field "$TOKEN_FILE" "duration_ms")
  P_TURNS=$(read_token_field "$TOKEN_FILE" "num_turns")
  P_MODEL=$(read_token_field "$TOKEN_FILE" "model")
  P_DURATION_S=$((P_DURATION_MS / 1000))
  P_COST=$(format_cost "$P_COST_RAW")

  # Determine pass/fail from structured result file
  TEST_RESULT_FILE="${SHARED_DIR}/test-result-${PLAN_BASENAME}.json"
  if [ -f "$TEST_RESULT_FILE" ]; then
    PLAN_PASSED=$(jq -r '.passed' "$TEST_RESULT_FILE" 2>/dev/null || echo "false")
    STEPS_TOTAL=$(jq -r '.total // 0' "$TEST_RESULT_FILE" 2>/dev/null || echo "0")
    STEPS_PASSED=$(jq -r '.passed_count // 0' "$TEST_RESULT_FILE" 2>/dev/null || echo "0")
    STEPS_DETAIL=$(jq -r '.steps[]? | "  \(if .passed then "PASS" else "FAIL" end): \(.name) — \(.detail)"' "$TEST_RESULT_FILE" 2>/dev/null | html_escape || echo "")
  else
    PLAN_PASSED="false"
    STEPS_TOTAL=0
    STEPS_PASSED=0
    STEPS_DETAIL="(no result file — Claude may have crashed or not written results)"
  fi

  if [ "$PLAN_PASSED" = "true" ]; then
    STATUS_CLASS="success"; STATUS_LABEL="Pass"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    STATUS_CLASS="failed"; STATUS_LABEL="Fail"; FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  STEPS_SUMMARY="${STEPS_PASSED}/${STEPS_TOTAL} steps passed"

  # Accumulate totals
  GRAND_TOTAL_INPUT=$((GRAND_TOTAL_INPUT + P_INPUT))
  GRAND_TOTAL_OUTPUT=$((GRAND_TOTAL_OUTPUT + P_OUTPUT))
  GRAND_TOTAL_CACHE_READ=$((GRAND_TOTAL_CACHE_READ + P_CACHE_READ))
  GRAND_TOTAL_CACHE_CREATE=$((GRAND_TOTAL_CACHE_CREATE + P_CACHE_CREATE))
  GRAND_TOTAL_COST_USD=$(awk "BEGIN {printf \"%.6f\", $GRAND_TOTAL_COST_USD + $P_COST_RAW}" 2>/dev/null || echo "0")

  # Read extracted text, tool calls, errors
  PLAN_TEXT=$(read_file "${SHARED_DIR}/claude-${PLAN_BASENAME}-output.txt" | html_escape)
  TOOL_CALLS=$(read_file "${SHARED_DIR}/claude-${PLAN_BASENAME}-tools.txt" | html_escape)
  TOOL_ERRORS=$(read_file "${SHARED_DIR}/claude-${PLAN_BASENAME}-errors.txt" | html_escape)

  # Summary row
  SUMMARY_ROWS="${SUMMARY_ROWS}<tr><td>${PLAN_BASENAME}</td><td><span class=\"status ${STATUS_CLASS}\">${STATUS_LABEL}</span></td><td>${STEPS_SUMMARY}</td><td>$(format_duration "$P_DURATION_S")</td><td>${P_TURNS}</td><td>$(format_number "$P_INPUT")</td><td>$(format_number "$P_OUTPUT")</td><td>${P_COST}</td></tr>"

  # Detail section
  DETAIL_SECTIONS="${DETAIL_SECTIONS}
<div class=\"issue-card\">
  <h2>${PLAN_BASENAME} <span class=\"status ${STATUS_CLASS}\">${STATUS_LABEL}</span></h2>
  <p><strong>Steps:</strong> ${STEPS_SUMMARY}</p>
  <table class=\"token-table\">
  <thead><tr><th>Metric</th><th>Value</th></tr></thead>
  <tbody>
  <tr><td>Duration</td><td>$(format_duration "$P_DURATION_S")</td></tr>
  <tr><td>Turns</td><td>${P_TURNS}</td></tr>
  <tr><td>Input Tokens</td><td>$(format_number "$P_INPUT")</td></tr>
  <tr><td>Output Tokens</td><td>$(format_number "$P_OUTPUT")</td></tr>
  <tr><td>Cache Read</td><td>$(format_number "$P_CACHE_READ")</td></tr>
  <tr><td>Cache Create</td><td>$(format_number "$P_CACHE_CREATE")</td></tr>
  <tr><td>Cost</td><td>${P_COST}</td></tr>
  <tr><td>Model</td><td>${P_MODEL}</td></tr>
  </tbody>
  </table>

  <h3>Test Steps</h3>
  <div class=\"phase-output\"><pre>${STEPS_DETAIL}</pre></div>

  <h3>Claude Output</h3>
  <div class=\"phase-output\"><pre>${PLAN_TEXT}</pre></div>
  <details><summary>Tool calls</summary><pre>${TOOL_CALLS}</pre></details>
  <details><summary>Tool errors</summary><pre class=\"error-pre\">${TOOL_ERRORS}</pre></details>
</div>"

done

GRAND_TOTAL_COST=$(format_cost "$GRAND_TOTAL_COST_USD")

cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Agentic QE Report</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 2em; background: #f5f5f5; color: #333; }
  h1 { border-bottom: 2px solid #333; padding-bottom: 0.3em; }
  .summary-stats { display: flex; gap: 2em; margin: 1em 0; flex-wrap: wrap; }
  .stat { background: #fff; padding: 1em 1.5em; border-radius: 6px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .stat .value { font-size: 2em; font-weight: bold; }
  .stat .label { color: #666; }
  table { border-collapse: collapse; width: 100%; background: #fff; border-radius: 6px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin: 1em 0; }
  th, td { padding: 0.75em 1em; text-align: left; border-bottom: 1px solid #eee; }
  th { background: #f8f8f8; font-weight: 600; }
  a { color: #0366d6; text-decoration: none; }
  .status { padding: 0.2em 0.6em; border-radius: 3px; font-size: 0.85em; font-weight: 600; }
  .status.success { background: #dcffe4; color: #22863a; }
  .status.failed { background: #ffdce0; color: #cb2431; }
  .issue-card { background: #fff; border-radius: 6px; padding: 1.5em; margin: 1.5em 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .issue-card h2 { margin-top: 0; }
  .issue-card h3 { color: #555; margin-top: 1.5em; }
  .phase-output pre { background: #f6f8fa; padding: 1em; border-radius: 4px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; font-size: 0.85em; max-height: 600px; overflow-y: auto; }
  details { margin: 0.5em 0 1em 0; }
  details summary { cursor: pointer; color: #666; font-size: 0.9em; }
  details pre { background: #f6f8fa; padding: 1em; border-radius: 4px; font-size: 0.8em; overflow-x: auto; }
  .timestamp { color: #666; font-size: 0.9em; }
  .token-table { width: auto; min-width: 300px; }
  .token-table td:last-child { text-align: right; }
  .error-pre { background: #fff5f5; border-left: 3px solid #cb2431; }
</style>
</head>
<body>
<h1>Agentic QE Report</h1>
<p class="timestamp">Generated: ${RUN_TIMESTAMP}</p>

<div class="summary-stats">
  <div class="stat"><div class="value">${TOTAL}</div><div class="label">Test Plans</div></div>
  <div class="stat"><div class="value" style="color:#22863a">${PASS_COUNT}</div><div class="label">Passed</div></div>
  <div class="stat"><div class="value" style="color:#cb2431">${FAIL_COUNT}</div><div class="label">Failed</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_INPUT")</div><div class="label">Input Tokens</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_OUTPUT")</div><div class="label">Output Tokens</div></div>
  <div class="stat"><div class="value">${GRAND_TOTAL_COST}</div><div class="label">Cost</div></div>
</div>

<h2>Summary</h2>
<table>
<thead><tr><th>Test Plan</th><th>Status</th><th>Steps</th><th>Duration</th><th>Turns</th><th>Input Tokens</th><th>Output Tokens</th><th>Cost</th></tr></thead>
<tbody>
${SUMMARY_ROWS}
</tbody>
</table>

<h2>Details</h2>
${DETAIL_SECTIONS}

</body>
</html>
EOF

echo "Report written to ${REPORT_FILE}"
echo "=== Report generation complete ==="
