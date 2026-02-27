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

# Extract data from stream-json output file
# Each line is a JSON object; we parse relevant fields
extract_from_stream_json() {
  local json_file=$1
  local field=$2

  if [ ! -f "$json_file" ] || [ ! -s "$json_file" ]; then
    echo ""
    return
  fi

  case "$field" in
    text)
      # Get the final result text
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.result // empty' 2>/dev/null | head -1 || echo ""
      ;;
    input_tokens)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.usage.input_tokens // 0' 2>/dev/null | head -1 || echo "0"
      ;;
    output_tokens)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.usage.output_tokens // 0' 2>/dev/null | head -1 || echo "0"
      ;;
    cache_read)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null | head -1 || echo "0"
      ;;
    cache_create)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.usage.cache_creation_input_tokens // (.usage.cache_creation.ephemeral_5m_input_tokens // 0)' 2>/dev/null | head -1 || echo "0"
      ;;
    duration_ms)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.duration_ms // 0' 2>/dev/null | head -1 || echo "0"
      ;;
    duration_api_ms)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.duration_api_ms // 0' 2>/dev/null | head -1 || echo "0"
      ;;
    num_turns)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.num_turns // 0' 2>/dev/null | head -1 || echo "0"
      ;;
    model)
      grep '"type":"system"' "$json_file" 2>/dev/null | jq -r '.model // "unknown"' 2>/dev/null | head -1 || echo "unknown"
      ;;
    session_id)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.session_id // "unknown"' 2>/dev/null | head -1 || echo "unknown"
      ;;
    cost_usd)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.total_cost_usd // 0' 2>/dev/null | head -1 || echo "0"
      ;;
    tools_available)
      grep '"type":"system"' "$json_file" 2>/dev/null | jq -r '.tools // [] | join(",")' 2>/dev/null | head -1 || echo ""
      ;;
    tool_calls)
      # Extract tool use entries
      grep '"type":"tool_use"' "$json_file" 2>/dev/null | jq -r '[.name // empty] | join("\n")' 2>/dev/null || echo ""
      ;;
    tool_errors)
      # Extract tool results with is_error=true
      grep '"is_error":true' "$json_file" 2>/dev/null | jq -r '.content // empty' 2>/dev/null || echo ""
      ;;
  esac
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

  # Try to find the Claude output JSON
  OUTPUT_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-output.json"
  if [ ! -f "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="/tmp/claude-pr-${PR_NUMBER}-output.json"
  fi

  # Extract data from stream-json output
  RESULT_TEXT=$(extract_from_stream_json "$OUTPUT_FILE" "text" | html_escape)
  PR_INPUT=$(extract_from_stream_json "$OUTPUT_FILE" "input_tokens")
  PR_OUTPUT=$(extract_from_stream_json "$OUTPUT_FILE" "output_tokens")
  PR_CACHE_READ=$(extract_from_stream_json "$OUTPUT_FILE" "cache_read")
  PR_CACHE_CREATE=$(extract_from_stream_json "$OUTPUT_FILE" "cache_create")
  DURATION_MS=$(extract_from_stream_json "$OUTPUT_FILE" "duration_ms")
  DURATION_API_MS=$(extract_from_stream_json "$OUTPUT_FILE" "duration_api_ms")
  NUM_TURNS=$(extract_from_stream_json "$OUTPUT_FILE" "num_turns")
  MODEL=$(extract_from_stream_json "$OUTPUT_FILE" "model")
  SESSION_ID=$(extract_from_stream_json "$OUTPUT_FILE" "session_id")
  TOOLS_AVAILABLE=$(extract_from_stream_json "$OUTPUT_FILE" "tools_available")

  : "${PR_INPUT:=0}"
  : "${PR_OUTPUT:=0}"
  : "${PR_CACHE_READ:=0}"
  : "${PR_CACHE_CREATE:=0}"
  : "${DURATION_MS:=0}"
  : "${NUM_TURNS:=0}"

  DURATION_SECS=$((DURATION_MS / 1000))
  DURATION_API_SECS=$((DURATION_API_MS / 1000))
  PR_COST=$(calculate_cost "$PR_INPUT" "$PR_OUTPUT" "$PR_CACHE_READ" "$PR_CACHE_CREATE")

  # Accumulate grand totals
  GRAND_TOTAL_INPUT=$((GRAND_TOTAL_INPUT + PR_INPUT))
  GRAND_TOTAL_OUTPUT=$((GRAND_TOTAL_OUTPUT + PR_OUTPUT))
  GRAND_TOTAL_CACHE_READ=$((GRAND_TOTAL_CACHE_READ + PR_CACHE_READ))
  GRAND_TOTAL_CACHE_CREATE=$((GRAND_TOTAL_CACHE_CREATE + PR_CACHE_CREATE))

  # Extract tool calls from stream-json
  TOOL_CALLS_RAW=""
  TOOL_ERRORS_RAW=""
  if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    # Tool calls: extract tool_use messages with name and input
    TOOL_CALLS_RAW=$(grep '"type":"tool_use"' "$OUTPUT_FILE" 2>/dev/null \
      | jq -r '"  \(.name)(\(.input | tostring | .[0:120])...)"' 2>/dev/null \
      || echo "")

    # Tool errors: extract tool_result messages where is_error is true
    TOOL_ERRORS_RAW=$(grep '"is_error":true' "$OUTPUT_FILE" 2>/dev/null \
      | jq -r '.content // "unknown error"' 2>/dev/null \
      || echo "")
  fi

  TOOL_CALLS_ESCAPED=$(echo "$TOOL_CALLS_RAW" | html_escape)
  TOOL_ERRORS_ESCAPED=$(echo "$TOOL_ERRORS_RAW" | html_escape)

  TOOL_CALL_COUNT=0
  if [ -n "$TOOL_CALLS_RAW" ]; then
    TOOL_CALL_COUNT=$(echo "$TOOL_CALLS_RAW" | grep -c '.' || true)
  fi

  TOOL_ERROR_COUNT=0
  if [ -n "$TOOL_ERRORS_RAW" ]; then
    TOOL_ERROR_COUNT=$(echo "$TOOL_ERRORS_RAW" | grep -c '.' || true)
  fi

  # Build available tools chips
  TOOLS_CHIPS=""
  if [ -n "$TOOLS_AVAILABLE" ]; then
    IFS=',' read -ra TOOLS_ARRAY <<< "$TOOLS_AVAILABLE"
    TOOLS_LOADED=${#TOOLS_ARRAY[@]}
    for tool in "${TOOLS_ARRAY[@]}"; do
      TOOLS_CHIPS="${TOOLS_CHIPS}<span class=\"tool-chip\">${tool}</span>"
    done
  else
    TOOLS_LOADED=0
  fi

  # PR link
  PR_LINK="<a href=\"https://github.com/openshift/hypershift/pull/${PR_NUMBER}\">#${PR_NUMBER}</a>"

  # Get PR title from analysis file if available
  PR_TITLE=""
  ANALYSIS_FILE="${SHARED_DIR}/pr-${PR_NUMBER}-analysis.json"
  if [ ! -f "$ANALYSIS_FILE" ]; then
    ANALYSIS_FILE="/tmp/pr-${PR_NUMBER}-analysis.json"
  fi

  # Get PR title via git log or state file
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
  <p class=\"model-info\">Model: ${MODEL} &middot; Duration: $(format_duration "$DURATION_SECS") (API: $(format_duration "$DURATION_API_SECS")) &middot; ${NUM_TURNS} turn(s) &middot; Session: ${SESSION_ID}</p>"
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

  <details>
    <summary>Available tools (${TOOLS_LOADED} loaded, ${TOOL_CALL_COUNT} used)</summary>
    <div class=\"tools-available\">${TOOLS_CHIPS:-"(no tools data available)"}</div>
  </details>
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
  .tools-available { display: flex; flex-wrap: wrap; gap: 0.4em; margin: 0.5em 0; }
  .tool-chip { background: #f6f8fa; border: 1px solid #eee; padding: 0.15em 0.5em; border-radius: 3px; font-family: SFMono-Regular, Consolas, monospace; font-size: 0.8em; color: #666; }
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
