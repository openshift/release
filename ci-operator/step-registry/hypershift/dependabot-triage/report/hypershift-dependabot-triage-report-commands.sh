#!/bin/bash
set -euo pipefail

echo "=== Dependabot Triage Report Generation ==="

RESULTS_FILE="${SHARED_DIR}/dependabot-results.txt"
TOKEN_FILE="${SHARED_DIR}/claude-dependabot-tokens.json"
REPORT_FILE="${ARTIFACT_DIR}/dependabot-triage-report.html"

if [ ! -f "$RESULTS_FILE" ]; then
  echo "No results file found. Nothing to report."
  exit 0
fi

# Count PRs by status
SUCCEEDED_COUNT=$(grep -c '^SUCCEEDED_PR:' "$RESULTS_FILE" 2>/dev/null || true)
FAILED_COUNT=$(grep -c '^FAILED_PR:' "$RESULTS_FILE" 2>/dev/null || true)
: "${SUCCEEDED_COUNT:=0}"
: "${FAILED_COUNT:=0}"
TOTAL=$((SUCCEEDED_COUNT + FAILED_COUNT))
RUN_TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "Generating report for $TOTAL PRs ($SUCCEEDED_COUNT succeeded, $FAILED_COUNT failed)"

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

# Format a cost value (already in USD) for display
format_cost() {
  local cost=${1:-0}
  printf '$%s' "$(awk "BEGIN {printf \"%.4f\", $cost}" 2>/dev/null || echo "0.0000")"
}

# HTML-escape a string
html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
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

# Read consolidated PR URL
CONSOLIDATED_PR_URL=""
if [ -f "${SHARED_DIR}/consolidated-pr-url.txt" ] && [ -s "${SHARED_DIR}/consolidated-pr-url.txt" ]; then
  CONSOLIDATED_PR_URL=$(cat "${SHARED_DIR}/consolidated-pr-url.txt")
fi

# Build succeeded PRs table rows
SUCCEEDED_ROWS=""
while IFS= read -r line; do
  if [ -z "$line" ]; then continue; fi
  pr_num=$(echo "$line" | cut -d: -f2)
  pr_title=$(echo "$line" | cut -d: -f3- | html_escape)
  SUCCEEDED_ROWS="${SUCCEEDED_ROWS}<tr><td><a href=\"https://github.com/openshift/hypershift/pull/${pr_num}\">#${pr_num}</a></td><td>${pr_title}</td></tr>"
done < <(grep '^SUCCEEDED_PR:' "$RESULTS_FILE" 2>/dev/null || true)

# Build failed PRs table rows
FAILED_ROWS=""
while IFS= read -r line; do
  if [ -z "$line" ]; then continue; fi
  pr_num=$(echo "$line" | cut -d: -f2)
  pr_reason=$(echo "$line" | cut -d: -f3- | html_escape)
  FAILED_ROWS="${FAILED_ROWS}<tr><td><a href=\"https://github.com/openshift/hypershift/pull/${pr_num}\">#${pr_num}</a></td><td>${pr_reason}</td></tr>"
done < <(grep '^FAILED_PR:' "$RESULTS_FILE" 2>/dev/null || true)

# Read Claude output text and tool summaries
CLAUDE_TEXT=$(read_extracted "${SHARED_DIR}/claude-dependabot-output-text.txt" | html_escape)
CLAUDE_TOOLS=$(read_extracted "${SHARED_DIR}/claude-dependabot-output-tools.txt" | html_escape)

# Consolidated PR banner (full-width, prominent)
CONSOLIDATED_PR_BANNER=""
if [ -n "$CONSOLIDATED_PR_URL" ]; then
  PR_NUMBER="${CONSOLIDATED_PR_URL##*/}"
  CONSOLIDATED_PR_BANNER="<div style=\"background:#dcffe4; border:2px solid #22863a; border-radius:8px; padding:1em 1.5em; margin:1em 0;\"><strong style=\"font-size:1.2em;\">Consolidated PR: <a href=\"${CONSOLIDATED_PR_URL}\">#${PR_NUMBER}</a></strong></div>"
fi

# Succeeded PRs table
SUCCEEDED_TABLE=""
if [ -n "$SUCCEEDED_ROWS" ]; then
  SUCCEEDED_TABLE="
<h2>Succeeded PRs</h2>
<table>
<thead><tr><th>PR</th><th>Title</th></tr></thead>
<tbody>
${SUCCEEDED_ROWS}
</tbody>
</table>"
fi

# Failed PRs table
FAILED_TABLE=""
if [ -n "$FAILED_ROWS" ]; then
  FAILED_TABLE="
<h2>Failed PRs</h2>
<table>
<thead><tr><th>PR</th><th>Failure Reason</th></tr></thead>
<tbody>
${FAILED_ROWS}
</tbody>
</table>"
fi

# Build per-model breakdown rows for the token table
MODEL_BREAKDOWN_ROWS=""
if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  while IFS= read -r model_line; do
    model_name=$(echo "$model_line" | jq -r '.key')
    model_input=$(echo "$model_line" | jq -r '.value.input_tokens // 0')
    model_output=$(echo "$model_line" | jq -r '.value.output_tokens // 0')
    MODEL_BREAKDOWN_ROWS="${MODEL_BREAKDOWN_ROWS}<tr><td>${model_name}</td><td>$(format_number "$model_input")</td><td>$(format_number "$model_output")</td><td>—</td><td>—</td><td>—</td></tr>"
  done < <(jq -c '.model_usage // {} | to_entries[]' "$TOKEN_FILE" 2>/dev/null || true)
fi

# Final validation failure section (when make verify/test fails on the consolidation branch)
FINAL_FAIL_MSG=$(grep -E '^FINAL_(VERIFY|TEST)_FAILED:' "$RESULTS_FILE" 2>/dev/null | head -1 | cut -d: -f2- | html_escape || true)
FINAL_FAIL_SECTION=""
if [ -n "$FINAL_FAIL_MSG" ]; then
  FINAL_FAIL_SECTION="<div class='output-card' style='border-left:4px solid #cb2431'>
<h3 style='color:#cb2431'>Final Validation Failed</h3>
<p>${FINAL_FAIL_MSG}</p>
<p>No PR was created. Check <code>make-verify-failure.log</code> in artifacts for details.</p></div>"
fi

# Write the HTML report
cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Dependabot Triage Report</title>
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
<h1>Dependabot Triage Report</h1>
<p class="timestamp">Generated: ${RUN_TIMESTAMP}</p>

${CONSOLIDATED_PR_BANNER}

<div class="summary-stats">
  <div class="stat"><div class="value">${TOTAL}</div><div class="label">Total PRs</div></div>
  <div class="stat"><div class="value" style="color:#22863a">${SUCCEEDED_COUNT}</div><div class="label">Succeeded</div></div>
  <div class="stat"><div class="value" style="color:#cb2431">${FAILED_COUNT}</div><div class="label">Failed</div></div>
  <div class="stat"><div class="value">$(format_number "$INPUT_TOKENS")</div><div class="label">Input Tokens</div></div>
  <div class="stat"><div class="value">$(format_number "$OUTPUT_TOKENS")</div><div class="label">Output Tokens</div></div>
  <div class="stat"><div class="value">${TOTAL_COST}</div><div class="label">Cost</div></div>
</div>

${SUCCEEDED_TABLE}

${FAILED_TABLE}

${FINAL_FAIL_SECTION}

<h2>Token Usage &amp; Cost</h2>
<table class="token-table">
<thead><tr><th>Category</th><th>Input Tokens</th><th>Output Tokens</th><th>Cache Read</th><th>Cache Create</th><th>Cost</th></tr></thead>
<tbody>
<tr class="total-row"><td><strong>Total</strong></td><td><strong>$(format_number "$INPUT_TOKENS")</strong></td><td><strong>$(format_number "$OUTPUT_TOKENS")</strong></td><td><strong>$(format_number "$CACHE_READ")</strong></td><td><strong>$(format_number "$CACHE_CREATE")</strong></td><td><strong>${TOTAL_COST}</strong></td></tr>
${MODEL_BREAKDOWN_ROWS}
</tbody>
</table>
<p class="model-info">Primary model: ${MODEL} · ${NUM_TURNS} turns · $((DURATION_MS / 1000))s</p>

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
