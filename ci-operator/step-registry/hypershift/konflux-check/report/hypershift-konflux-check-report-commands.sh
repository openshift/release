#!/bin/bash
set -euo pipefail

echo "=== Konflux Check Report Generation ==="

RESULTS_FILE="${SHARED_DIR}/konflux-check-results.txt"
TOKEN_FILE="${SHARED_DIR}/claude-konflux-tokens.json"
REPORT_FILE="${ARTIFACT_DIR}/konflux-check-report.html"

if [ ! -f "$RESULTS_FILE" ]; then
  echo "No results file found. Nothing to report."
  exit 0
fi

# Parse results
STATUS=$(grep '^STATUS:' "$RESULTS_FILE" | head -1 | cut -d: -f2)
COMMIT_COUNT=$(grep '^COMMITS:' "$RESULTS_FILE" | head -1 | cut -d: -f2 || echo "0")
PR_URL=$(grep '^PR_URL:' "$RESULTS_FILE" | head -1 | cut -d: -f2- || echo "none")
CHANGED_FILES_RAW=$(grep '^CHANGED_FILES:' "$RESULTS_FILE" | head -1 | cut -d: -f2- || echo "")
CLAUDE_EXIT_CODE=$(grep '^CLAUDE_EXIT_CODE:' "$RESULTS_FILE" | head -1 | cut -d: -f2 || echo "0")

RUN_TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

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

# Format token count with comma separators
format_number() {
  local num=$1
  printf "%s" "$num" | sed -e ':a' -e 's/\([0-9]\)\([0-9]\{3\}\)\(\b\)/\1,\2\3/' -e 'ta'
}

# Format a cost value for display
format_cost() {
  local cost=${1:-0}
  printf '$%s' "$(awk "BEGIN {printf \"%.4f\", $cost}" 2>/dev/null || echo "0.0000")"
}

# HTML-escape a string
html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

# Format seconds into human-readable string
format_duration() {
  local secs=$1
  if [ "$secs" -eq 0 ] 2>/dev/null; then
    echo "-"
    return
  fi
  local mins=$(( secs / 60 ))
  local s=$(( secs % 60 ))
  if [ "$mins" -gt 0 ]; then
    printf "%dm %ds" "$mins" "$s"
  else
    printf "%ds" "$s"
  fi
}

# Read token data
INPUT_TOKENS=$(read_token_field "$TOKEN_FILE" "input_tokens")
OUTPUT_TOKENS=$(read_token_field "$TOKEN_FILE" "output_tokens")
CACHE_READ=$(read_token_field "$TOKEN_FILE" "cache_read_input_tokens")
CACHE_CREATE=$(read_token_field "$TOKEN_FILE" "cache_creation_input_tokens")
MODEL=$(read_token_field "$TOKEN_FILE" "model")
TOTAL_COST_RAW=$(read_token_field "$TOKEN_FILE" "total_cost_usd")
TOTAL_COST=$(format_cost "$TOTAL_COST_RAW")
DURATION_MS=$(read_token_field "$TOKEN_FILE" "duration_ms")
NUM_TURNS=$(read_token_field "$TOKEN_FILE" "num_turns")

# Read duration from our own measurement
DURATION_SECS=$(cat "${SHARED_DIR}/claude-konflux-duration.txt" 2>/dev/null || echo "0")
DURATION_DISPLAY=$(format_duration "$DURATION_SECS")

# Status display
case "$STATUS" in
  UPDATED)
    STATUS_LABEL="Updates Applied"
    STATUS_COLOR="#22863a"
    ;;
  UP_TO_DATE)
    STATUS_LABEL="Up to Date"
    STATUS_COLOR="#0366d6"
    ;;
  NO_CREDENTIALS)
    STATUS_LABEL="No Credentials"
    STATUS_COLOR="#e36209"
    ;;
  *)
    STATUS_LABEL="Unknown"
    STATUS_COLOR="#666"
    ;;
esac

# PR banner
PR_BANNER=""
if [ "$PR_URL" != "none" ] && [ -n "$PR_URL" ]; then
  PR_NUMBER="${PR_URL##*/}"
  PR_BANNER="<div style=\"background:#dcffe4; border:2px solid #22863a; border-radius:8px; padding:1em 1.5em; margin:1em 0;\"><strong style=\"font-size:1.2em;\">Pull Request: <a href=\"${PR_URL}\">#${PR_NUMBER}</a></strong></div>"
fi

# Changed files table
CHANGED_FILES_SECTION=""
if [ -n "$CHANGED_FILES_RAW" ]; then
  CHANGED_FILES_ROWS=""
  for f in $CHANGED_FILES_RAW; do
    CHANGED_FILES_ROWS="${CHANGED_FILES_ROWS}<tr><td><code>$(echo "$f" | html_escape)</code></td></tr>"
  done
  CHANGED_FILES_SECTION="
<h2>Changed Files</h2>
<table>
<thead><tr><th>File</th></tr></thead>
<tbody>
${CHANGED_FILES_ROWS}
</tbody>
</table>"
fi

# Commit messages section
COMMITS_SECTION=""
if [ -f "${SHARED_DIR}/konflux-check-commits.txt" ] && [ -s "${SHARED_DIR}/konflux-check-commits.txt" ]; then
  COMMIT_ROWS=""
  while IFS= read -r msg; do
    COMMIT_ROWS="${COMMIT_ROWS}<tr><td>$(echo "$msg" | html_escape)</td></tr>"
  done < "${SHARED_DIR}/konflux-check-commits.txt"
  COMMITS_SECTION="
<h2>Commits</h2>
<table>
<thead><tr><th>Message</th></tr></thead>
<tbody>
${COMMIT_ROWS}
</tbody>
</table>"
fi

# Build per-model breakdown rows for the token table
MODEL_BREAKDOWN_ROWS=""
if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  while IFS= read -r model_line; do
    model_name=$(echo "$model_line" | jq -r '.key')
    model_input=$(echo "$model_line" | jq -r '.value.input_tokens // .value.inputTokens // 0')
    model_output=$(echo "$model_line" | jq -r '.value.output_tokens // .value.outputTokens // 0')
    MODEL_BREAKDOWN_ROWS="${MODEL_BREAKDOWN_ROWS}<tr style=\"font-size:0.85em; color:#666;\"><td>&nbsp;&nbsp;${model_name}</td><td>$(format_number "$model_input")</td><td>$(format_number "$model_output")</td><td>-</td><td>-</td><td>-</td></tr>"
  done < <(jq -c '.model_usage // {} | to_entries[]' "$TOKEN_FILE" 2>/dev/null || true)
fi

# Claude warnings section
WARNINGS_SECTION=""
if [ "$CLAUDE_EXIT_CODE" != "0" ] && [ "$CLAUDE_EXIT_CODE" != "" ]; then
  WARNINGS_SECTION="<div style=\"background:#fff5b1; border:2px solid #e36209; border-radius:8px; padding:1em 1.5em; margin:1em 0;\"><strong>Warning:</strong> Claude exited with non-zero status code: ${CLAUDE_EXIT_CODE}</div>"
fi

# Read Claude output text and tool summaries
CLAUDE_TEXT=$(read_extracted "${SHARED_DIR}/claude-konflux-output-text.txt" | html_escape)
CLAUDE_TOOLS=$(read_extracted "${SHARED_DIR}/claude-konflux-output-tools.txt" | html_escape)

# Write the HTML report
cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Konflux Task Update Report</title>
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
  code { background: #f0f0f0; padding: 0.15em 0.4em; border-radius: 3px; font-size: 0.9em; }
  .token-table { width: auto; min-width: 600px; }
  .token-table td, .token-table th { text-align: right; }
  .token-table td:first-child, .token-table th:first-child { text-align: left; }
  .total-row td { border-top: 2px solid #333; }
  .model-info { color: #666; font-size: 0.85em; margin-top: 0.3em; }
  .output-card { background: #fff; border-radius: 6px; padding: 1.5em; margin: 1.5em 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .output-card h3 { color: #555; margin-top: 0; }
  .output-card pre { background: #f6f8fa; padding: 1em; border-radius: 4px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; font-size: 0.85em; max-height: 400px; overflow-y: auto; }
  details { margin: 0.5em 0 1em 0; }
  details summary { cursor: pointer; color: #666; font-size: 0.9em; }
  details pre { background: #f6f8fa; padding: 1em; border-radius: 4px; font-size: 0.8em; overflow-x: auto; }
  .timestamp { color: #666; font-size: 0.9em; }
</style>
</head>
<body>
<h1>Konflux Task Update Report</h1>
<p class="timestamp">Generated: ${RUN_TIMESTAMP}</p>

${PR_BANNER}
${WARNINGS_SECTION}

<div class="summary-stats">
  <div class="stat"><div class="value" style="color:${STATUS_COLOR}">${STATUS_LABEL}</div><div class="label">Status</div></div>
  <div class="stat"><div class="value">${COMMIT_COUNT:-0}</div><div class="label">Commits</div></div>
  <div class="stat"><div class="value">${DURATION_DISPLAY}</div><div class="label">Duration</div></div>
  <div class="stat"><div class="value">$(format_number "$INPUT_TOKENS")</div><div class="label">Input Tokens</div></div>
  <div class="stat"><div class="value">$(format_number "$OUTPUT_TOKENS")</div><div class="label">Output Tokens</div></div>
  <div class="stat"><div class="value">${TOTAL_COST}</div><div class="label">Cost</div></div>
</div>

${COMMITS_SECTION}

${CHANGED_FILES_SECTION}

<h2>Token Usage &amp; Cost</h2>
<table class="token-table">
<thead><tr><th>Category</th><th>Input Tokens</th><th>Output Tokens</th><th>Cache Read</th><th>Cache Create</th><th>Cost</th></tr></thead>
<tbody>
<tr class="total-row"><td><strong>Total</strong></td><td><strong>$(format_number "$INPUT_TOKENS")</strong></td><td><strong>$(format_number "$OUTPUT_TOKENS")</strong></td><td><strong>$(format_number "$CACHE_READ")</strong></td><td><strong>$(format_number "$CACHE_CREATE")</strong></td><td><strong>${TOTAL_COST}</strong></td></tr>
${MODEL_BREAKDOWN_ROWS}
</tbody>
</table>
<p class="model-info">Primary model: ${MODEL} | ${NUM_TURNS} turns | $((DURATION_MS / 1000))s</p>

<div class="output-card">
  <h3>Claude Output</h3>
  <div><pre>${CLAUDE_TEXT}</pre></div>
  <details><summary>Tool calls</summary><pre>${CLAUDE_TOOLS}</pre></details>
</div>

</body>
</html>
EOF

echo "Report written to ${REPORT_FILE}"

echo "=== Report generation complete ==="
