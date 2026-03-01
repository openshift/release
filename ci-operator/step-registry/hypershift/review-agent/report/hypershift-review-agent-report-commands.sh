#!/bin/bash
set -euo pipefail

echo "=== Review Agent Report Generation ==="

STATE_FILE="${SHARED_DIR}/processed-prs.txt"
REPORT_FILE="${ARTIFACT_DIR}/review-agent-report.html"

if [ ! -f "$STATE_FILE" ]; then
  echo "No processed PRs state file found. Nothing to report."
  exit 0
fi

# Count PRs by status
TOTAL=$(wc -l < "$STATE_FILE" | tr -d ' ')
SUCCESS_COUNT=$(grep -c 'SUCCESS$' "$STATE_FILE" 2>/dev/null || true)
FAILED_COUNT=$(grep -c 'FAILED' "$STATE_FILE" 2>/dev/null || true)
: "${SUCCESS_COUNT:=0}"
: "${FAILED_COUNT:=0}"
RUN_TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "Generating report for $TOTAL PRs ($SUCCESS_COUNT succeeded, $FAILED_COUNT failed)"

# Read a pre-extracted text file, or return a placeholder
read_extracted() {
  local file=$1
  if [ -f "$file" ] && [ -s "$file" ]; then
    cat "$file"
  else
    echo "(no output captured)"
  fi
}

# Read a JSON token file and extract a field, defaulting to 0
read_token_field() {
  local file=$1
  local field=$2
  if [ -f "$file" ] && [ -s "$file" ]; then
    jq -r ".${field} // 0" "$file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Read a duration file and return the value in seconds, or 0 if missing
read_duration() {
  local file=$1
  if [ -f "$file" ] && [ -s "$file" ]; then
    cat "$file" | tr -d '[:space:]'
  else
    echo "0"
  fi
}

# HTML-escape a string
html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

# Format token count with comma separators
format_number() {
  local num=$1
  printf "%s" "$num" | sed -e ':a' -e 's/\([0-9]\)\([0-9]\{3\}\)\(\b\)/\1,\2\3/' -e 'ta'
}

# Calculate estimated cost in USD based on token counts
# Claude Opus 4.6 pricing per million tokens:
#   input=$5, output=$25, cache_read=$0.50, cache_create=$6.25 (5-min cache write)
calculate_cost() {
  local input_tokens=${1:-0}
  local output_tokens=${2:-0}
  local cache_read=${3:-0}
  local cache_create=${4:-0}

  local cost
  cost=$(awk "BEGIN {printf \"%.4f\", ($input_tokens * 5 + $output_tokens * 25 + $cache_read * 0.5 + $cache_create * 6.25) / 1000000}" 2>/dev/null) || cost="0.0000"
  printf '$%s' "$cost"
}

# Format seconds into a human-readable string
format_duration() {
  local secs=$1
  if [ "$secs" -eq 0 ] 2>/dev/null; then
    echo "-"
    return
  fi
  local hours=$((secs / 3600))
  local mins=$(( (secs % 3600) / 60 ))
  local s=$((secs % 60))
  if [ "$hours" -gt 0 ]; then
    printf "%dh %dm %ds" "$hours" "$mins" "$s"
  elif [ "$mins" -gt 0 ]; then
    printf "%dm %ds" "$mins" "$s"
  else
    printf "%ds" "$s"
  fi
}

# Make a Jira issue key into a link, or return text as-is
linkify_jira() {
  local text=$1
  echo "$text" | sed -E 's/([A-Z][A-Z0-9]+-[0-9]+)/<a href="https:\/\/issues.redhat.com\/browse\/\1">\1<\/a>/g'
}

# Build PR rows for summary table and detail sections
SUMMARY_ROWS=""
DETAIL_SECTIONS=""
GRAND_TOTAL_INPUT=0
GRAND_TOTAL_OUTPUT=0
GRAND_TOTAL_CACHE_READ=0
GRAND_TOTAL_CACHE_CREATE=0

while IFS= read -r line; do
  PR_NUMBER=$(echo "$line" | awk '{print $1}')
  PR_TIMESTAMP=$(echo "$line" | awk '{print $2}')
  STATUS=$(echo "$line" | awk '{print $3}')

  echo "Processing PR #$PR_NUMBER (status=$STATUS)"

  if [ "$STATUS" = "SUCCESS" ]; then
    STATUS_CLASS="success"
    STATUS_LABEL="Success"
  else
    STATUS_CLASS="failed"
    STATUS_LABEL="Failed"
  fi

  # Read pre-extracted data from SHARED_DIR
  TOKEN_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-tokens.json"
  DURATION_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-duration.txt"
  TEXT_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-output-text.txt"
  TOOLS_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-output-tools.txt"
  ERRORS_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-output-errors.txt"
  NUM_TURNS_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-num-turns.txt"
  SESSION_ID_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-session-id.txt"

  # Extract data from pre-extracted files
  RESULT_TEXT=$(read_extracted "$TEXT_FILE" | html_escape)
  PR_INPUT=$(read_token_field "$TOKEN_FILE" "input_tokens")
  PR_OUTPUT=$(read_token_field "$TOKEN_FILE" "output_tokens")
  PR_CACHE_READ=$(read_token_field "$TOKEN_FILE" "cache_read_input_tokens")
  PR_CACHE_CREATE=$(read_token_field "$TOKEN_FILE" "cache_creation_input_tokens")
  MODEL=$(read_token_field "$TOKEN_FILE" "model")
  DURATION_SECS=$(read_duration "$DURATION_FILE")
  NUM_TURNS=$(read_duration "$NUM_TURNS_FILE")
  SESSION_ID=$(read_extracted "$SESSION_ID_FILE")

  : "${PR_INPUT:=0}"
  : "${PR_OUTPUT:=0}"
  : "${PR_CACHE_READ:=0}"
  : "${PR_CACHE_CREATE:=0}"
  : "${DURATION_SECS:=0}"
  : "${NUM_TURNS:=0}"

  PR_COST=$(calculate_cost "$PR_INPUT" "$PR_OUTPUT" "$PR_CACHE_READ" "$PR_CACHE_CREATE")

  # Accumulate grand totals
  GRAND_TOTAL_INPUT=$((GRAND_TOTAL_INPUT + PR_INPUT))
  GRAND_TOTAL_OUTPUT=$((GRAND_TOTAL_OUTPUT + PR_OUTPUT))
  GRAND_TOTAL_CACHE_READ=$((GRAND_TOTAL_CACHE_READ + PR_CACHE_READ))
  GRAND_TOTAL_CACHE_CREATE=$((GRAND_TOTAL_CACHE_CREATE + PR_CACHE_CREATE))

  # Read pre-extracted tool calls and errors
  TOOL_CALLS_RAW=$(read_extracted "$TOOLS_FILE")
  TOOL_ERRORS_RAW=$(read_extracted "$ERRORS_FILE")

  TOOL_CALLS_ESCAPED=$(echo "$TOOL_CALLS_RAW" | html_escape)
  TOOL_ERRORS_ESCAPED=$(echo "$TOOL_ERRORS_RAW" | html_escape)

  TOOL_CALL_COUNT=0
  if [ "$TOOL_CALLS_RAW" != "(no output captured)" ] && [ -n "$TOOL_CALLS_RAW" ]; then
    TOOL_CALL_COUNT=$(echo "$TOOL_CALLS_RAW" | grep -c '.' || true)
  fi

  TOOL_ERROR_COUNT=0
  if [ "$TOOL_ERRORS_RAW" != "(no output captured)" ] && [ -n "$TOOL_ERRORS_RAW" ]; then
    TOOL_ERROR_COUNT=$(echo "$TOOL_ERRORS_RAW" | grep -c '.' || true)
  fi

  # PR link
  PR_LINK="<a href=\"https://github.com/openshift/hypershift/pull/${PR_NUMBER}\">#${PR_NUMBER}</a>"

  # Get PR title
  PR_TITLE_RAW=$(gh pr view "$PR_NUMBER" --repo openshift/hypershift --json title --jq '.title' 2>/dev/null || echo "PR #${PR_NUMBER}")
  PR_TITLE=$(echo "$PR_TITLE_RAW" | html_escape)
  PR_TITLE_LINKED=$(linkify_jira "$PR_TITLE")

  # Token usage table
  TOKEN_TABLE=""
  if [ "$PR_INPUT" -gt 0 ] || [ "$PR_OUTPUT" -gt 0 ] || [ "$PR_CACHE_CREATE" -gt 0 ]; then
    TOKEN_TABLE="
  <h3>Token Usage &amp; Cost</h3>
  <table class=\"token-table\">
  <thead><tr><th>Phase</th><th>Duration</th><th>Input Tokens</th><th>Output Tokens</th><th>Cache Read</th><th>Cache Create</th><th>Est. Cost</th></tr></thead>
  <tbody>
  <tr><td>Comment Analysis</td><td>$(format_duration "$DURATION_SECS")</td><td>$(format_number "$PR_INPUT")</td><td>$(format_number "$PR_OUTPUT")</td><td>$(format_number "$PR_CACHE_READ")</td><td>$(format_number "$PR_CACHE_CREATE")</td><td>${PR_COST}</td></tr>
  <tr class=\"total-row\"><td><strong>Total</strong></td><td><strong>$(format_duration "$DURATION_SECS")</strong></td><td><strong>$(format_number "$PR_INPUT")</strong></td><td><strong>$(format_number "$PR_OUTPUT")</strong></td><td><strong>$(format_number "$PR_CACHE_READ")</strong></td><td><strong>$(format_number "$PR_CACHE_CREATE")</strong></td><td><strong>${PR_COST}</strong></td></tr>
  </tbody>
  </table>
  <p class=\"model-info\">Model: ${MODEL} &middot; Duration: $(format_duration "$DURATION_SECS") &middot; ${NUM_TURNS} turn(s) &middot; Session: ${SESSION_ID}</p>"
  fi

  # Summary table row
  SUMMARY_ROWS="${SUMMARY_ROWS}<tr><td>${PR_LINK}</td><td>${PR_TITLE_LINKED}</td><td>${PR_TIMESTAMP}</td><td><span class=\"badge ${STATUS_CLASS}\">${STATUS_LABEL}</span></td><td>${PR_COST}</td></tr>"

  # Detail section
  DETAIL_SECTIONS="${DETAIL_SECTIONS}
<div class=\"pr-card\">
  <h2>${PR_LINK} <span class=\"badge ${STATUS_CLASS}\">${STATUS_LABEL}</span></h2>
  <p style=\"margin:0.3em 0 0 0; color:#666\">${PR_TITLE_LINKED}</p>
  ${TOKEN_TABLE}

  <h3>Phase: Comment Analysis</h3>
  <div class=\"phase-output\"><pre>${RESULT_TEXT:-"(no output captured)"}</pre></div>
  <details><summary>Tool calls (${TOOL_CALL_COUNT})</summary><pre>${TOOL_CALLS_ESCAPED:-"(no tool calls)"}</pre></details>
  <details><summary>Tool errors (${TOOL_ERROR_COUNT})</summary><pre class=\"error-pre\">${TOOL_ERRORS_ESCAPED:-"(no tool errors)"}</pre></details>
</div>"

done < "$STATE_FILE"

# Calculate grand total cost
GRAND_TOTAL_COST=$(calculate_cost "$GRAND_TOTAL_INPUT" "$GRAND_TOTAL_OUTPUT" "$GRAND_TOTAL_CACHE_READ" "$GRAND_TOTAL_CACHE_CREATE")

# Write the HTML report
cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Review Agent Report</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f5f5f5; color: #333; }
  .container { max-width: 1200px; margin: 0 auto; padding: 2em; }
  h1 { border-bottom: 2px solid #333; padding-bottom: 0.3em; }
  .summary-stats { display: flex; gap: 1.2em; margin: 1.5em 0; flex-wrap: wrap; }
  .stat { background: #fff; padding: 1em 1.5em; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); min-width: 120px; text-align: center; }
  .stat .value { font-size: 2em; font-weight: bold; line-height: 1.2; }
  .stat .label { color: #666; font-size: 0.85em; margin-top: 0.2em; }
  table { border-collapse: collapse; width: 100%; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin: 1em 0; }
  th, td { padding: 0.75em 1em; text-align: left; border-bottom: 1px solid #eee; }
  th { background: #f8f8f8; font-weight: 600; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.03em; color: #666; }
  a { color: #0366d6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .badge { padding: 0.25em 0.7em; border-radius: 12px; font-size: 0.8em; font-weight: 600; display: inline-block; }
  .badge.success { background: #dcffe4; color: #22863a; }
  .badge.failed { background: #ffdce0; color: #cb2431; }
  .pr-card { background: #fff; border-radius: 8px; padding: 1.5em; margin: 1.5em 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .pr-card h2 { margin-top: 0; }
  .pr-card h3 { color: #555; margin-top: 1.5em; margin-bottom: 0.5em; }
  .phase-output pre { background: #f6f8fa; padding: 1em; border-radius: 6px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; font-size: 0.85em; max-height: 500px; overflow-y: auto; line-height: 1.5; }
  details { margin: 0.5em 0 1em 0; }
  details summary { cursor: pointer; color: #666; font-size: 0.9em; padding: 0.3em 0; }
  details summary:hover { color: #333; }
  details[open] summary { margin-bottom: 0.5em; }
  details pre { background: #f6f8fa; padding: 1em; border-radius: 6px; font-size: 0.8em; overflow-x: auto; max-height: 400px; overflow-y: auto; }
  .timestamp { color: #666; font-size: 0.9em; }
  .token-table { width: auto; min-width: 600px; }
  .token-table td, .token-table th { text-align: right; }
  .token-table td:first-child, .token-table th:first-child { text-align: left; }
  .total-row td { border-top: 2px solid #333; font-weight: 600; }
  .model-info { color: #666; font-size: 0.85em; margin-top: 0.3em; }
  .error-pre { background: #fff5f5; border-left: 3px solid #cb2431; }
  .footer { text-align: center; color: #666; font-size: 0.8em; margin-top: 3em; padding-top: 1em; border-top: 1px solid #eee; }
</style>
</head>
<body>
<div class="container">
<h1>Review Agent Report</h1>
<p class="timestamp">Generated: ${RUN_TIMESTAMP}</p>

<div class="summary-stats">
  <div class="stat"><div class="value">${TOTAL}</div><div class="label">PRs Processed</div></div>
  <div class="stat"><div class="value" style="color:#22863a">${SUCCESS_COUNT}</div><div class="label">Succeeded</div></div>
  <div class="stat"><div class="value" style="color:#cb2431">${FAILED_COUNT}</div><div class="label">Failed</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_INPUT")</div><div class="label">Input Tokens</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_OUTPUT")</div><div class="label">Output Tokens</div></div>
  <div class="stat"><div class="value">${GRAND_TOTAL_COST}</div><div class="label">Est. Cost</div></div>
</div>

<h2>Summary</h2>
<table>
<thead><tr><th>PR</th><th>Title</th><th>Timestamp</th><th>Status</th><th>Est. Cost</th></tr></thead>
<tbody>
${SUMMARY_ROWS}
</tbody>
</table>

<h2>Details</h2>
${DETAIL_SECTIONS}

<div class="footer">
  Review Agent Report &middot; openshift/hypershift &middot; Generated from CI artifacts
</div>

</div>
</body>
</html>
EOF

echo "Report written to ${REPORT_FILE}"

echo "=== Report generation complete ==="
