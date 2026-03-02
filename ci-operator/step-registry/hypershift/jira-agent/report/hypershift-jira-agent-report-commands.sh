#!/bin/bash
set -euo pipefail

echo "=== Jira Agent Report Generation ==="

STATE_FILE="${SHARED_DIR}/processed-issues.txt"
REPORT_FILE="${ARTIFACT_DIR}/jira-agent-report.html"

if [ ! -f "$STATE_FILE" ]; then
  echo "No processed issues state file found. Nothing to report."
  exit 0
fi

# Count issues by status
TOTAL=$(wc -l < "$STATE_FILE" | tr -d ' ')
SUCCESS_COUNT=$(grep -c 'SUCCESS$' "$STATE_FILE" 2>/dev/null || true)
FAILED_COUNT=$(grep -c 'FAILED$' "$STATE_FILE" 2>/dev/null || true)
: "${SUCCESS_COUNT:=0}"
: "${FAILED_COUNT:=0}"
RUN_TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "Generating report for $TOTAL issues ($SUCCESS_COUNT succeeded, $FAILED_COUNT failed)"

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

# Format token count with comma separators (GNU sed compatible)
format_number() {
  local num=$1
  printf "%s" "$num" | sed -e ':a' -e 's/\([0-9]\)\([0-9]\{3\}\)\(\b\)/\1,\2\3/' -e 'ta'
}

# Calculate estimated cost in USD based on token counts
# Claude Opus 4.6 pricing per million tokens:
#   input=$5, output=$25, cache_read=$0.50, cache_create=$6.25 (5-min cache write)
# Returns formatted string like "$1.2345"
calculate_cost() {
  local input_tokens=${1:-0}
  local output_tokens=${2:-0}
  local cache_read=${3:-0}
  local cache_create=${4:-0}

  local cost
  cost=$(awk "BEGIN {printf \"%.4f\", ($input_tokens * 5 + $output_tokens * 25 + $cache_read * 0.5 + $cache_create * 6.25) / 1000000}" 2>/dev/null) || cost="0.0000"
  printf '$%s' "$cost"
}

# HTML-escape a string
html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
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

# Format seconds into a human-readable string (e.g. "40m 36s")
format_duration() {
  local secs=$1
  if [ "$secs" -eq 0 ]; then
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

# Build issue rows for summary table and detail sections
SUMMARY_ROWS=""
DETAIL_SECTIONS=""
GRAND_TOTAL_INPUT=0
GRAND_TOTAL_OUTPUT=0
GRAND_TOTAL_CACHE_READ=0
GRAND_TOTAL_CACHE_CREATE=0

while IFS= read -r line; do
  ISSUE_KEY=$(echo "$line" | awk '{print $1}')
  ISSUE_TIMESTAMP=$(echo "$line" | awk '{print $2}')
  PR_URL=$(echo "$line" | awk '{print $3}')
  STATUS=$(echo "$line" | awk '{print $4}')

  # Debug: verify token files exist and jq is available
  echo "Processing issue $ISSUE_KEY (status=$STATUS)"
  echo "  Token files check:"
  for phase in solve review fix pr; do
    tf="${SHARED_DIR}/claude-${ISSUE_KEY}-${phase}-tokens.json"
    if [ -f "$tf" ]; then
      echo "    ${phase}: $(cat "$tf" | tr -d '\n' | cut -c1-120)"
    else
      echo "    ${phase}: FILE NOT FOUND"
    fi
  done

  if [ "$STATUS" = "SUCCESS" ]; then
    STATUS_CLASS="success"
    STATUS_LABEL="Success"
  else
    STATUS_CLASS="failed"
    STATUS_LABEL="Failed"
  fi

  # PR link or dash
  if [ -n "$PR_URL" ] && [ "$PR_URL" != "-" ]; then
    PR_LINK="<a href=\"${PR_URL}\">${PR_URL}</a>"
  else
    PR_LINK="-"
  fi

  # Read pre-extracted phase outputs
  SOLVE_TEXT=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-output-text.txt" | html_escape)
  REVIEW_TEXT=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-review-text.txt" | html_escape)
  FIX_TEXT=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-text.txt" | html_escape)
  PR_TEXT=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-text.txt" | html_escape)

  SOLVE_TOOLS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-output-tools.txt" | html_escape)
  REVIEW_TOOLS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-review-tools.txt" | html_escape)
  FIX_TOOLS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-tools.txt" | html_escape)
  PR_TOOLS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-tools.txt" | html_escape)

  SOLVE_ERRORS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-output-errors.txt" | html_escape)
  REVIEW_ERRORS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-review-errors.txt" | html_escape)
  FIX_ERRORS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-errors.txt" | html_escape)
  PR_ERRORS=$(read_extracted "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-errors.txt" | html_escape)

  # Read token usage per phase
  ISSUE_TOTAL_INPUT=0
  ISSUE_TOTAL_OUTPUT=0
  ISSUE_TOTAL_CACHE_READ=0
  ISSUE_TOTAL_CACHE_CREATE=0
  TOKEN_ROWS=""
  MODEL="unknown"

  ISSUE_TOTAL_DURATION=0

  for phase_info in "solve:Phase 1: Solve" "review:Phase 2: Review" "fix:Phase 3: Fix" "pr:Phase 4: PR"; do
    PHASE_KEY="${phase_info%%:*}"
    PHASE_LABEL="${phase_info#*:}"
    TOKEN_FILE="${SHARED_DIR}/claude-${ISSUE_KEY}-${PHASE_KEY}-tokens.json"
    DURATION_FILE="${SHARED_DIR}/claude-${ISSUE_KEY}-${PHASE_KEY}-duration.txt"

    P_INPUT=$(read_token_field "$TOKEN_FILE" "input_tokens")
    P_OUTPUT=$(read_token_field "$TOKEN_FILE" "output_tokens")
    P_CACHE_READ=$(read_token_field "$TOKEN_FILE" "cache_read_input_tokens")
    P_CACHE_CREATE=$(read_token_field "$TOKEN_FILE" "cache_creation_input_tokens")
    P_MODEL=$(read_token_field "$TOKEN_FILE" "model")
    P_DURATION=$(read_duration "$DURATION_FILE")
    if [ "$P_MODEL" != "0" ] && [ "$P_MODEL" != "unknown" ]; then
      MODEL="$P_MODEL"
    fi

    P_COST=$(calculate_cost "$P_INPUT" "$P_OUTPUT" "$P_CACHE_READ" "$P_CACHE_CREATE")

    ISSUE_TOTAL_INPUT=$((ISSUE_TOTAL_INPUT + P_INPUT))
    ISSUE_TOTAL_OUTPUT=$((ISSUE_TOTAL_OUTPUT + P_OUTPUT))
    ISSUE_TOTAL_CACHE_READ=$((ISSUE_TOTAL_CACHE_READ + P_CACHE_READ))
    ISSUE_TOTAL_CACHE_CREATE=$((ISSUE_TOTAL_CACHE_CREATE + P_CACHE_CREATE))
    ISSUE_TOTAL_DURATION=$((ISSUE_TOTAL_DURATION + P_DURATION))

    if [ "$P_INPUT" -gt 0 ] || [ "$P_OUTPUT" -gt 0 ]; then
      TOKEN_ROWS="${TOKEN_ROWS}<tr><td>${PHASE_LABEL}</td><td>$(format_duration "$P_DURATION")</td><td>$(format_number "$P_INPUT")</td><td>$(format_number "$P_OUTPUT")</td><td>$(format_number "$P_CACHE_READ")</td><td>$(format_number "$P_CACHE_CREATE")</td><td>${P_COST}</td></tr>"
    fi
  done

  ISSUE_COST=$(calculate_cost "$ISSUE_TOTAL_INPUT" "$ISSUE_TOTAL_OUTPUT" "$ISSUE_TOTAL_CACHE_READ" "$ISSUE_TOTAL_CACHE_CREATE")

  # Accumulate grand totals
  GRAND_TOTAL_INPUT=$((GRAND_TOTAL_INPUT + ISSUE_TOTAL_INPUT))
  GRAND_TOTAL_OUTPUT=$((GRAND_TOTAL_OUTPUT + ISSUE_TOTAL_OUTPUT))
  GRAND_TOTAL_CACHE_READ=$((GRAND_TOTAL_CACHE_READ + ISSUE_TOTAL_CACHE_READ))
  GRAND_TOTAL_CACHE_CREATE=$((GRAND_TOTAL_CACHE_CREATE + ISSUE_TOTAL_CACHE_CREATE))

  # Token usage table for this issue
  TOKEN_TABLE=""
  if [ -n "$TOKEN_ROWS" ]; then
    TOKEN_TABLE="
  <h3>Token Usage &amp; Cost</h3>
  <table class=\"token-table\">
  <thead><tr><th>Phase</th><th>Duration</th><th>Input Tokens</th><th>Output Tokens</th><th>Cache Read</th><th>Cache Create</th><th>Est. Cost</th></tr></thead>
  <tbody>
  ${TOKEN_ROWS}
  <tr class=\"total-row\"><td><strong>Total</strong></td><td><strong>$(format_duration "$ISSUE_TOTAL_DURATION")</strong></td><td><strong>$(format_number "$ISSUE_TOTAL_INPUT")</strong></td><td><strong>$(format_number "$ISSUE_TOTAL_OUTPUT")</strong></td><td><strong>$(format_number "$ISSUE_TOTAL_CACHE_READ")</strong></td><td><strong>$(format_number "$ISSUE_TOTAL_CACHE_CREATE")</strong></td><td><strong>${ISSUE_COST}</strong></td></tr>
  </tbody>
  </table>
  <p class=\"model-info\">Model: ${MODEL}</p>"
  fi

  # Summary table row
  SUMMARY_ROWS="${SUMMARY_ROWS}<tr><td><a href=\"https://issues.redhat.com/browse/${ISSUE_KEY}\">${ISSUE_KEY}</a></td><td>${ISSUE_TIMESTAMP}</td><td><span class=\"status ${STATUS_CLASS}\">${STATUS_LABEL}</span></td><td>${PR_LINK}</td><td>${ISSUE_COST}</td></tr>"

  DETAIL_SECTIONS="${DETAIL_SECTIONS}
<div class=\"issue-card\">
  <h2><a href=\"https://issues.redhat.com/browse/${ISSUE_KEY}\">${ISSUE_KEY}</a> <span class=\"status ${STATUS_CLASS}\">${STATUS_LABEL}</span></h2>
  ${TOKEN_TABLE}

  <h3>Phase 1: Solve</h3>
  <div class=\"phase-output\"><pre>${SOLVE_TEXT}</pre></div>
  <details><summary>Tool calls</summary><pre>${SOLVE_TOOLS}</pre></details>
  <details><summary>Tool errors</summary><pre class=\"error-pre\">${SOLVE_ERRORS}</pre></details>

  <h3>Phase 2: Pre-commit Review</h3>
  <div class=\"phase-output\"><pre>${REVIEW_TEXT}</pre></div>
  <details><summary>Tool calls</summary><pre>${REVIEW_TOOLS}</pre></details>
  <details><summary>Tool errors</summary><pre class=\"error-pre\">${REVIEW_ERRORS}</pre></details>

  <h3>Phase 3: Review Fixes</h3>
  <div class=\"phase-output\"><pre>${FIX_TEXT}</pre></div>
  <details><summary>Tool calls</summary><pre>${FIX_TOOLS}</pre></details>
  <details><summary>Tool errors</summary><pre class=\"error-pre\">${FIX_ERRORS}</pre></details>

  <h3>Phase 4: PR Creation</h3>
  <div class=\"phase-output\"><pre>${PR_TEXT}</pre></div>
  <details><summary>Tool calls</summary><pre>${PR_TOOLS}</pre></details>
  <details><summary>Tool errors</summary><pre class=\"error-pre\">${PR_ERRORS}</pre></details>
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
<title>Jira Agent Report</title>
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
  a:hover { text-decoration: underline; }
  .status { padding: 0.2em 0.6em; border-radius: 3px; font-size: 0.85em; font-weight: 600; }
  .status.success { background: #dcffe4; color: #22863a; }
  .status.failed { background: #ffdce0; color: #cb2431; }
  .issue-card { background: #fff; border-radius: 6px; padding: 1.5em; margin: 1.5em 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .issue-card h2 { margin-top: 0; }
  .issue-card h3 { color: #555; margin-top: 1.5em; }
  .phase-output pre { background: #f6f8fa; padding: 1em; border-radius: 4px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; font-size: 0.85em; max-height: 400px; overflow-y: auto; }
  details { margin: 0.5em 0 1em 0; }
  details summary { cursor: pointer; color: #666; font-size: 0.9em; }
  details pre { background: #f6f8fa; padding: 1em; border-radius: 4px; font-size: 0.8em; overflow-x: auto; }
  .timestamp { color: #666; font-size: 0.9em; }
  .token-table { width: auto; min-width: 600px; }
  .token-table td, .token-table th { text-align: right; }
  .token-table td:first-child, .token-table th:first-child { text-align: left; }
  .total-row td { border-top: 2px solid #333; }
  .model-info { color: #666; font-size: 0.85em; margin-top: 0.3em; }
  .error-pre { background: #fff5f5; border-left: 3px solid #cb2431; }
</style>
</head>
<body>
<h1>Jira Agent Report</h1>
<p class="timestamp">Generated: ${RUN_TIMESTAMP}</p>

<div class="summary-stats">
  <div class="stat"><div class="value">${TOTAL}</div><div class="label">Total</div></div>
  <div class="stat"><div class="value" style="color:#22863a">${SUCCESS_COUNT}</div><div class="label">Succeeded</div></div>
  <div class="stat"><div class="value" style="color:#cb2431">${FAILED_COUNT}</div><div class="label">Failed</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_INPUT")</div><div class="label">Input Tokens</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_OUTPUT")</div><div class="label">Output Tokens</div></div>
  <div class="stat"><div class="value">${GRAND_TOTAL_COST}</div><div class="label">Est. Cost</div></div>
</div>

<h2>Summary</h2>
<table>
<thead><tr><th>Issue</th><th>Timestamp</th><th>Status</th><th>Pull Request</th><th>Est. Cost</th></tr></thead>
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
