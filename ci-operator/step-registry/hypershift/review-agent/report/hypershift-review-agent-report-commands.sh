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

# Format a cost value as "$X.XXXX"
format_cost() {
  local cost_usd=${1:-0}
  printf '$%.4f' "$cost_usd"
}

# Sum two floating-point cost values
sum_costs() {
  local a=${1:-0}
  local b=${2:-0}
  awk "BEGIN {printf \"%.6f\", $a + $b}" 2>/dev/null || echo "0"
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
  echo "$text" | sed -E 's/([A-Z][A-Z0-9]+-[0-9]+)/<a href="https:\/\/redhat.atlassian.net\/browse\/\1">\1<\/a>/g'
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
      # Get all assistant text output (full conversation, separated by newlines)
      jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "$json_file" 2>/dev/null || echo ""
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
      # Extract tool use entries from assistant messages
      jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$json_file" 2>/dev/null || echo ""
      ;;
    tool_errors)
      # Extract tool error results from user messages
      jq -r 'select(.type == "user") | .tool_use_result | select(type == "string") | select(startswith("Error:"))' "$json_file" 2>/dev/null || echo ""
      ;;
    model_usage)
      grep '"type":"result"' "$json_file" 2>/dev/null | jq -r '.modelUsage // {} | to_entries[] | "\(.key)|\(.value.inputTokens // .value.input_tokens // 0)|\(.value.outputTokens // .value.output_tokens // 0)|\(.value.cacheReadInputTokens // .value.cache_read_input_tokens // 0)|\(.value.cacheCreationInputTokens // .value.cache_creation_input_tokens // 0)"' 2>/dev/null | head -20 || echo ""
      ;;
  esac
}

# Helper: read token/cost data from a summary file (compact or legacy format)
read_phase_summary() {
  local summary_file=$1
  # Output variables are set via nameref-like pattern using eval
  local prefix=$2

  local input=0 output=0 cache_read=0 cache_create=0 duration_ms=0 duration_api_ms=0 num_turns=0 cost_raw=0 model="unknown" session_id="unknown" result_text="" tools_available=""

  if [ -f "$summary_file" ] && grep -q '"result"' "$summary_file" 2>/dev/null && ! grep -q '"type":"result"' "$summary_file" 2>/dev/null; then
    result_text=$(jq -r '.result // empty' "$summary_file" 2>/dev/null | html_escape)
    input=$(jq -r '.usage.input_tokens // 0' "$summary_file" 2>/dev/null)
    output=$(jq -r '.usage.output_tokens // 0' "$summary_file" 2>/dev/null)
    cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' "$summary_file" 2>/dev/null)
    cache_create=$(jq -r '.usage.cache_creation_input_tokens // (.usage.cache_creation.ephemeral_5m_input_tokens // 0)' "$summary_file" 2>/dev/null)
    duration_ms=$(jq -r '.duration_ms // 0' "$summary_file" 2>/dev/null)
    duration_api_ms=$(jq -r '.duration_api_ms // 0' "$summary_file" 2>/dev/null)
    num_turns=$(jq -r '.num_turns // 0' "$summary_file" 2>/dev/null)
    model=$(jq -r '.model // "unknown"' "$summary_file" 2>/dev/null)
    session_id=$(jq -r '.session_id // "unknown"' "$summary_file" 2>/dev/null)
    cost_raw=$(jq -r '.total_cost_usd // 0' "$summary_file" 2>/dev/null)
    tools_available=$(jq -r '.tools // [] | join(",")' "$summary_file" 2>/dev/null)
  elif [ -f "$summary_file" ] && [ -s "$summary_file" ]; then
    result_text=$(extract_from_stream_json "$summary_file" "text" | html_escape)
    input=$(extract_from_stream_json "$summary_file" "input_tokens")
    output=$(extract_from_stream_json "$summary_file" "output_tokens")
    cache_read=$(extract_from_stream_json "$summary_file" "cache_read")
    cache_create=$(extract_from_stream_json "$summary_file" "cache_create")
    duration_ms=$(extract_from_stream_json "$summary_file" "duration_ms")
    duration_api_ms=$(extract_from_stream_json "$summary_file" "duration_api_ms")
    num_turns=$(extract_from_stream_json "$summary_file" "num_turns")
    model=$(extract_from_stream_json "$summary_file" "model")
    session_id=$(extract_from_stream_json "$summary_file" "session_id")
    cost_raw=$(extract_from_stream_json "$summary_file" "cost_usd")
    tools_available=$(extract_from_stream_json "$summary_file" "tools_available")
  fi

  : "${input:=0}" ; : "${output:=0}" ; : "${cache_read:=0}" ; : "${cache_create:=0}"
  : "${duration_ms:=0}" ; : "${duration_api_ms:=0}" ; : "${num_turns:=0}" ; : "${cost_raw:=0}"

  printf -v "${prefix}_INPUT" '%s' "$input"
  printf -v "${prefix}_OUTPUT" '%s' "$output"
  printf -v "${prefix}_CACHE_READ" '%s' "$cache_read"
  printf -v "${prefix}_CACHE_CREATE" '%s' "$cache_create"
  printf -v "${prefix}_DURATION_MS" '%s' "$duration_ms"
  printf -v "${prefix}_DURATION_API_MS" '%s' "$duration_api_ms"
  printf -v "${prefix}_NUM_TURNS" '%s' "$num_turns"
  printf -v "${prefix}_COST_RAW" '%s' "$cost_raw"
  printf -v "${prefix}_MODEL" '%s' "$model"
  printf -v "${prefix}_SESSION_ID" '%s' "$session_id"
  printf -v "${prefix}_RESULT_TEXT" '%s' "$result_text"
  printf -v "${prefix}_TOOLS_AVAILABLE" '%s' "$tools_available"
}

# Helper: extract tool calls/errors from a summary file
read_phase_tools() {
  local summary_file=$1
  local prefix=$2

  local tool_calls_raw="" tool_errors_raw=""

  if [ -f "$summary_file" ] && grep -q '"result"' "$summary_file" 2>/dev/null && ! grep -q '"type":"result"' "$summary_file" 2>/dev/null; then
    tool_calls_raw=$(jq -r '.tool_calls[]? // empty' "$summary_file" 2>/dev/null | sed 's/^/  /' || echo "")
    tool_errors_raw=$(jq -r '.tool_errors[]? // empty' "$summary_file" 2>/dev/null || echo "")
  elif [ -f "$summary_file" ] && [ -s "$summary_file" ]; then
    tool_calls_raw=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "  \(.name)(\(.input | tostring | .[0:120])...)"' "$summary_file" 2>/dev/null || echo "")
    tool_errors_raw=$(jq -r 'select(.type == "user") | .tool_use_result | select(type == "string") | select(startswith("Error:")) | gsub("\n"; "⏎")' "$summary_file" 2>/dev/null | sed 's/⏎/\n/g' || echo "")
  fi

  printf -v "${prefix}_TOOL_CALLS_RAW" '%s' "$tool_calls_raw"
  printf -v "${prefix}_TOOL_ERRORS_RAW" '%s' "$tool_errors_raw"
}

# Build PR rows for summary table and detail sections
SUMMARY_ROWS=""
DETAIL_SECTIONS=""
GRAND_TOTAL_INPUT=0
GRAND_TOTAL_OUTPUT=0
GRAND_TOTAL_CACHE_READ=0
GRAND_TOTAL_CACHE_CREATE=0
GRAND_TOTAL_COST_USD="0"
GRAND_REBASED_COUNT=0
GRAND_CI_FIX_COUNT=0

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

  # ---- Read per-PR actions JSON ----
  ACTIONS_FILE="${SHARED_DIR}/pr-${PR_NUMBER}-actions.json"
  REBASE_ATTEMPTED="false"
  REBASE_RESULT=""
  REVIEWS_ATTEMPTED="false"
  REVIEWS_RESULT=""
  CI_FIX_ATTEMPTED="false"
  CI_FIX_RESULT=""
  CI_FIX_CHECKS=""

  if [ -f "$ACTIONS_FILE" ]; then
    REBASE_ATTEMPTED=$(jq -r '.rebase.attempted // false' "$ACTIONS_FILE" 2>/dev/null)
    REBASE_RESULT=$(jq -r '.rebase.result // empty' "$ACTIONS_FILE" 2>/dev/null)
    REVIEWS_ATTEMPTED=$(jq -r '.reviews.attempted // false' "$ACTIONS_FILE" 2>/dev/null)
    REVIEWS_RESULT=$(jq -r '.reviews.result // empty' "$ACTIONS_FILE" 2>/dev/null)
    CI_FIX_ATTEMPTED=$(jq -r '.ci_fixes.attempted // false' "$ACTIONS_FILE" 2>/dev/null)
    CI_FIX_RESULT=$(jq -r '.ci_fixes.result // empty' "$ACTIONS_FILE" 2>/dev/null)
    CI_FIX_CHECKS=$(jq -r '.ci_fixes.checks // [] | join(", ")' "$ACTIONS_FILE" 2>/dev/null)
  fi

  # Count rebases and CI fixes for summary stats
  if [ "$REBASE_ATTEMPTED" = "true" ] && [ "$REBASE_RESULT" = "success" ]; then
    GRAND_REBASED_COUNT=$((GRAND_REBASED_COUNT + 1))
  fi
  if [ "$CI_FIX_ATTEMPTED" = "true" ] && [ "$CI_FIX_RESULT" = "success" ]; then
    GRAND_CI_FIX_COUNT=$((GRAND_CI_FIX_COUNT + 1))
  fi

  # Build action badges for summary table
  ACTION_BADGES=""
  if [ "$REBASE_ATTEMPTED" = "true" ]; then
    if [ "$REBASE_RESULT" = "success" ]; then
      ACTION_BADGES="${ACTION_BADGES}<span class=\"badge rebase\">Rebased</span> "
    else
      ACTION_BADGES="${ACTION_BADGES}<span class=\"badge failed\">Rebase Failed</span> "
    fi
  fi
  if [ "$REVIEWS_ATTEMPTED" = "true" ]; then
    if [ "$REVIEWS_RESULT" = "success" ]; then
      ACTION_BADGES="${ACTION_BADGES}<span class=\"badge reviews\">Reviews</span> "
    else
      ACTION_BADGES="${ACTION_BADGES}<span class=\"badge failed\">Reviews Failed</span> "
    fi
  fi
  if [ "$CI_FIX_ATTEMPTED" = "true" ]; then
    if [ "$CI_FIX_RESULT" = "success" ]; then
      ACTION_BADGES="${ACTION_BADGES}<span class=\"badge cifix\">CI Fix</span> "
    else
      ACTION_BADGES="${ACTION_BADGES}<span class=\"badge failed\">CI Fix Failed</span> "
    fi
  fi
  : "${ACTION_BADGES:=-}"

  # ---- Read review phase summary ----
  REVIEW_SUMMARY_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-summary.json"
  if [ ! -f "$REVIEW_SUMMARY_FILE" ]; then
    REVIEW_SUMMARY_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-output.json"
  fi

  read_phase_summary "$REVIEW_SUMMARY_FILE" "REV"
  read_phase_tools "$REVIEW_SUMMARY_FILE" "REV"

  # ---- Read CI fix phase summary ----
  CIFIX_SUMMARY_FILE="${SHARED_DIR}/claude-pr-${PR_NUMBER}-cifix-summary.json"
  read_phase_summary "$CIFIX_SUMMARY_FILE" "CIFIX"
  read_phase_tools "$CIFIX_SUMMARY_FILE" "CIFIX"

  # ---- Compute per-PR totals (review + CI fix) ----
  PR_INPUT=$((REV_INPUT + CIFIX_INPUT))
  PR_OUTPUT=$((REV_OUTPUT + CIFIX_OUTPUT))
  PR_CACHE_READ=$((REV_CACHE_READ + CIFIX_CACHE_READ))
  PR_CACHE_CREATE=$((REV_CACHE_CREATE + CIFIX_CACHE_CREATE))
  PR_DURATION_MS=$((REV_DURATION_MS + CIFIX_DURATION_MS))
  PR_COST_RAW=$(sum_costs "$REV_COST_RAW" "$CIFIX_COST_RAW")
  PR_COST=$(format_cost "$PR_COST_RAW")

  PR_DURATION_SECS=$((PR_DURATION_MS / 1000))
  REV_DURATION_SECS=$((REV_DURATION_MS / 1000))
  REV_DURATION_API_SECS=$((REV_DURATION_API_MS / 1000))
  CIFIX_DURATION_SECS=$((CIFIX_DURATION_MS / 1000))

  # Accumulate grand totals
  GRAND_TOTAL_INPUT=$((GRAND_TOTAL_INPUT + PR_INPUT))
  GRAND_TOTAL_OUTPUT=$((GRAND_TOTAL_OUTPUT + PR_OUTPUT))
  GRAND_TOTAL_CACHE_READ=$((GRAND_TOTAL_CACHE_READ + PR_CACHE_READ))
  GRAND_TOTAL_CACHE_CREATE=$((GRAND_TOTAL_CACHE_CREATE + PR_CACHE_CREATE))
  GRAND_TOTAL_COST_USD=$(sum_costs "$GRAND_TOTAL_COST_USD" "$PR_COST_RAW")

  # Extract tool calls and errors for review phase
  REV_TOOL_CALLS_ESCAPED=$(echo "$REV_TOOL_CALLS_RAW" | html_escape)
  REV_TOOL_ERRORS_ESCAPED=$(echo "$REV_TOOL_ERRORS_RAW" | html_escape)
  REV_TOOL_CALL_COUNT=0
  if [ -n "$REV_TOOL_CALLS_RAW" ]; then
    REV_TOOL_CALL_COUNT=$(echo "$REV_TOOL_CALLS_RAW" | grep -c '.' || true)
  fi
  REV_TOOL_ERROR_COUNT=0
  if [ -n "$REV_TOOL_ERRORS_RAW" ]; then
    REV_TOOL_ERROR_COUNT=$(echo "$REV_TOOL_ERRORS_RAW" | grep -c '.' || true)
  fi

  # Extract tool calls and errors for CI fix phase
  CIFIX_TOOL_CALLS_ESCAPED=$(echo "$CIFIX_TOOL_CALLS_RAW" | html_escape)
  CIFIX_TOOL_ERRORS_ESCAPED=$(echo "$CIFIX_TOOL_ERRORS_RAW" | html_escape)
  CIFIX_TOOL_CALL_COUNT=0
  if [ -n "$CIFIX_TOOL_CALLS_RAW" ]; then
    CIFIX_TOOL_CALL_COUNT=$(echo "$CIFIX_TOOL_CALLS_RAW" | grep -c '.' || true)
  fi
  CIFIX_TOOL_ERROR_COUNT=0
  if [ -n "$CIFIX_TOOL_ERRORS_RAW" ]; then
    CIFIX_TOOL_ERROR_COUNT=$(echo "$CIFIX_TOOL_ERRORS_RAW" | grep -c '.' || true)
  fi

  # Build available tools chips (from review phase)
  TOOLS_CHIPS=""
  if [ -n "$REV_TOOLS_AVAILABLE" ]; then
    IFS=',' read -ra TOOLS_ARRAY <<< "$REV_TOOLS_AVAILABLE"
    TOOLS_LOADED=${#TOOLS_ARRAY[@]}
    for tool in "${TOOLS_ARRAY[@]}"; do
      TOOLS_CHIPS="${TOOLS_CHIPS}<span class=\"tool-chip\">${tool}</span>"
    done
  else
    TOOLS_LOADED=0
  fi

  # PR link
  PR_LINK="<a href=\"https://github.com/openshift/hypershift/pull/${PR_NUMBER}\">#${PR_NUMBER}</a>"

  # Get PR title
  PR_TITLE_RAW=$(gh pr view "$PR_NUMBER" --repo openshift/hypershift --json title --jq '.title' 2>/dev/null || echo "PR #${PR_NUMBER}")
  PR_TITLE=$(echo "$PR_TITLE_RAW" | html_escape)
  PR_TITLE_LINKED=$(linkify_jira "$PR_TITLE")

  # ---- Token usage table with per-phase rows ----
  # Build per-model breakdown rows from review phase
  MODEL_BREAKDOWN_ROWS=""
  if [ -f "$REVIEW_SUMMARY_FILE" ] && ! grep -q '"type":"result"' "$REVIEW_SUMMARY_FILE" 2>/dev/null; then
    MODEL_BREAKDOWN_RAW=$(jq -r '.modelUsage // {} | to_entries[] | "\(.key)|\(.value.inputTokens // .value.input_tokens // 0)|\(.value.outputTokens // .value.output_tokens // 0)|\(.value.cacheReadInputTokens // .value.cache_read_input_tokens // 0)|\(.value.cacheCreationInputTokens // .value.cache_creation_input_tokens // 0)"' "$REVIEW_SUMMARY_FILE" 2>/dev/null | head -20 || echo "")
  else
    MODEL_BREAKDOWN_RAW=$(extract_from_stream_json "${REVIEW_SUMMARY_FILE}" "model_usage")
  fi
  if [ -n "$MODEL_BREAKDOWN_RAW" ]; then
    MODEL_BREAKDOWN_ROWS="<tr><td colspan=\"7\" style=\"background:#f0f0f0; font-size:0.85em; color:#666; padding:0.3em 1em;\"><em>Per-model breakdown</em></td></tr>"
    while IFS='|' read -r M_NAME M_INPUT M_OUTPUT M_CACHE_READ M_CACHE_CREATE; do
      if [ -n "$M_NAME" ]; then
        M_SHORT=$(echo "$M_NAME" | sed 's/-[0-9]*$//')
        MODEL_BREAKDOWN_ROWS="${MODEL_BREAKDOWN_ROWS}<tr style=\"font-size:0.85em; color:#666;\"><td>&nbsp;&nbsp;${M_SHORT}</td><td>-</td><td>$(format_number "$M_INPUT")</td><td>$(format_number "$M_OUTPUT")</td><td>$(format_number "$M_CACHE_READ")</td><td>$(format_number "$M_CACHE_CREATE")</td><td>-</td></tr>"
      fi
    done <<< "$MODEL_BREAKDOWN_RAW"
  fi

  TOKEN_TABLE=""
  if [ "$PR_INPUT" -gt 0 ] || [ "$PR_OUTPUT" -gt 0 ] || [ "$PR_CACHE_CREATE" -gt 0 ]; then
    REV_COST=$(format_cost "$REV_COST_RAW")
    CIFIX_COST=$(format_cost "$CIFIX_COST_RAW")

    # Build CI Fix row only if CI fix was attempted
    CIFIX_ROW=""
    if [ "$CI_FIX_ATTEMPTED" = "true" ]; then
      CIFIX_ROW="<tr><td>CI Fix</td><td>$(format_duration "$CIFIX_DURATION_SECS")</td><td>$(format_number "$CIFIX_INPUT")</td><td>$(format_number "$CIFIX_OUTPUT")</td><td>$(format_number "$CIFIX_CACHE_READ")</td><td>$(format_number "$CIFIX_CACHE_CREATE")</td><td>${CIFIX_COST}</td></tr>"
    fi

    TOKEN_TABLE="
  <h3>Token Usage &amp; Cost</h3>
  <table class=\"token-table\">
  <thead><tr><th>Phase</th><th>Duration</th><th>Input Tokens</th><th>Output Tokens</th><th>Cache Read</th><th>Cache Create</th><th>Cost</th></tr></thead>
  <tbody>
  <tr><td>Review Analysis</td><td>$(format_duration "$REV_DURATION_SECS")</td><td>$(format_number "$REV_INPUT")</td><td>$(format_number "$REV_OUTPUT")</td><td>$(format_number "$REV_CACHE_READ")</td><td>$(format_number "$REV_CACHE_CREATE")</td><td>${REV_COST}</td></tr>
  ${CIFIX_ROW}
  <tr class=\"total-row\"><td><strong>Total</strong></td><td><strong>$(format_duration "$PR_DURATION_SECS")</strong></td><td><strong>$(format_number "$PR_INPUT")</strong></td><td><strong>$(format_number "$PR_OUTPUT")</strong></td><td><strong>$(format_number "$PR_CACHE_READ")</strong></td><td><strong>$(format_number "$PR_CACHE_CREATE")</strong></td><td><strong>${PR_COST}</strong></td></tr>
  ${MODEL_BREAKDOWN_ROWS}
  </tbody>
  </table>
  <p class=\"model-info\">Model: ${REV_MODEL} &middot; Duration: $(format_duration "$PR_DURATION_SECS") (Review API: $(format_duration "$REV_DURATION_API_SECS")) &middot; ${REV_NUM_TURNS} review turn(s) &middot; Session: ${REV_SESSION_ID}</p>"
  fi

  # Summary table row (with Actions column)
  SUMMARY_ROWS="${SUMMARY_ROWS}<tr><td>${PR_LINK}</td><td>${PR_TITLE_LINKED}</td><td>${PR_TIMESTAMP}</td><td><span class=\"badge ${STATUS_CLASS}\">${STATUS_LABEL}</span></td><td>${ACTION_BADGES}</td><td>${PR_COST}</td></tr>"

  # ---- Build detail section ----
  # Phase: Rebase
  REBASE_SECTION=""
  if [ "$REBASE_ATTEMPTED" = "true" ]; then
    if [ "$REBASE_RESULT" = "success" ]; then
      REBASE_SECTION="<h3>Phase: Rebase</h3><p><span class=\"badge success\">Success</span> Rebased onto upstream base branch.</p>"
    else
      REBASE_SECTION="<h3>Phase: Rebase</h3><p><span class=\"badge failed\">Conflict</span> Rebase failed due to merge conflicts. Remaining phases were skipped.</p>"
    fi
  fi

  # Phase: Review Analysis
  REVIEW_SECTION=""
  if [ "$REVIEWS_ATTEMPTED" = "true" ]; then
    REVIEW_SECTION="
  <h3>Phase: Review Analysis</h3>
  <div class=\"phase-output\"><pre>${REV_RESULT_TEXT:-"(no output captured)"}</pre></div>
  <details><summary>Tool calls (${REV_TOOL_CALL_COUNT})</summary><pre>${REV_TOOL_CALLS_ESCAPED:-"(no tool calls)"}</pre></details>
  <details><summary>Tool errors (${REV_TOOL_ERROR_COUNT})</summary><pre class=\"error-pre\">${REV_TOOL_ERRORS_ESCAPED:-"(no tool errors)"}</pre></details>"
  fi

  # Phase: CI Fix
  CIFIX_SECTION=""
  if [ "$CI_FIX_ATTEMPTED" = "true" ]; then
    CI_FIX_CHECKS_ESCAPED=$(echo "$CI_FIX_CHECKS" | html_escape)
    CIFIX_SECTION="
  <h3>Phase: CI Fix</h3>
  <p>Failed checks: <code>${CI_FIX_CHECKS_ESCAPED:-"(unknown)"}</code></p>
  <div class=\"phase-output\"><pre>${CIFIX_RESULT_TEXT:-"(no output captured)"}</pre></div>
  <details><summary>Tool calls (${CIFIX_TOOL_CALL_COUNT})</summary><pre>${CIFIX_TOOL_CALLS_ESCAPED:-"(no tool calls)"}</pre></details>
  <details><summary>Tool errors (${CIFIX_TOOL_ERROR_COUNT})</summary><pre class=\"error-pre\">${CIFIX_TOOL_ERRORS_ESCAPED:-"(no tool errors)"}</pre></details>"
  fi

  DETAIL_SECTIONS="${DETAIL_SECTIONS}
<div class=\"pr-card\">
  <h2>${PR_LINK} <span class=\"badge ${STATUS_CLASS}\">${STATUS_LABEL}</span></h2>
  <p style=\"margin:0.3em 0 0 0; color:#666\">${PR_TITLE_LINKED}</p>
  ${TOKEN_TABLE}
  ${REBASE_SECTION}
  ${REVIEW_SECTION}
  ${CIFIX_SECTION}

  <details>
    <summary>Available tools (${TOOLS_LOADED} loaded)</summary>
    <div class=\"tools-available\">${TOOLS_CHIPS:-"(no tools data available)"}</div>
  </details>
</div>"

done < "$STATE_FILE"

# Format grand total cost
GRAND_TOTAL_COST=$(format_cost "$GRAND_TOTAL_COST_USD")

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
  .badge.rebase { background: #e1f5fe; color: #01579b; }
  .badge.reviews { background: #f3e5f5; color: #4a148c; }
  .badge.cifix { background: #fff3e0; color: #e65100; }
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
  <div class="stat"><div class="value" style="color:#01579b">${GRAND_REBASED_COUNT}</div><div class="label">Rebased</div></div>
  <div class="stat"><div class="value" style="color:#e65100">${GRAND_CI_FIX_COUNT}</div><div class="label">CI Fixes</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_INPUT")</div><div class="label">Input Tokens</div></div>
  <div class="stat"><div class="value">$(format_number "$GRAND_TOTAL_OUTPUT")</div><div class="label">Output Tokens</div></div>
  <div class="stat"><div class="value">${GRAND_TOTAL_COST}</div><div class="label">Cost</div></div>
</div>

<h2>Summary</h2>
<table>
<thead><tr><th>PR</th><th>Title</th><th>Timestamp</th><th>Status</th><th>Actions</th><th>Cost</th></tr></thead>
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
