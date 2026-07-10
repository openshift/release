#!/bin/bash
set -euo pipefail

cat > "${SHARED_DIR}/claude-helpers.sh" << 'HEREDOC_EOF'
#!/bin/bash
# Claude CLI helper functions for jira-agent phases.
#
# Usage:
#   source "${SHARED_DIR}/claude-helpers.sh"
#
# Functions:
#   run_claude               - Run claude via agentic-ci for OTEL collection
#   extract_session_metrics  - Extract OTEL metrics for BigQuery autodl
#   generate_autodl          - Generate domain-specific BigQuery autodl JSON
#   get_session_id           - Extract session_id from stream-json output
#   extract_claude_outputs   - Extract text/tools/errors from stream-json
#   extract_claude_tokens    - Extract token usage metrics
#   record_phase_duration    - Record phase wall-clock time
#   run_claude_phase         - Run a full Claude CLI phase with extraction
#   validate_jira_plugin     - Verify jira plugin is installed
#   build_solve_prompt       - Build Phase 1 (solve) prompt
#   build_review_prompt      - Build Phase 2 (review) prompt
#   build_fix_prompt         - Build Phase 3 (fix) prompt
#   build_pr_prompt          - Build Phase 4 (PR) prompt
#   extract_pr_url           - Extract PR URL from Claude output
#   process_single_issue     - Run full solve/review/fix/PR pipeline

# ── OTEL / BigQuery telemetry ─────────────────────────────────────────────────

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

# Wrapper: run claude via agentic-ci for native OTEL collection.
# Uses --no-streaming so stdout passes through raw for tee/reports.
# Filters to JSON lines only (agentic-ci log lines are stripped).
# Captures OTEL JSONL per invocation and appends to the consolidated log.
#
# Usage: run_claude <phase> <issue_key> <prompt> [extra agentic-ci/claude args...]
run_claude() {
  local phase=$1; shift
  local issue_key=$1; shift
  local prompt="$1"; shift

  local phase_otel="/tmp/claude-${issue_key}-${phase}-otel.jsonl"

  agentic-ci run \
    --backend local \
    --harness claude-code \
    --model "${CLAUDE_MODEL}" \
    --workdir /tmp/project-repo \
    --no-streaming \
    "${prompt}" \
    -- \
    --permission-mode default \
    --verbose \
    --output-format stream-json \
    "$@" \
    | grep '^{'
  local rc=${PIPESTATUS[0]}

  for f in /tmp/agentic-ci-run.*/claude-otel.jsonl; do
    if [ -f "$f" ]; then
      cat "$f" >> "${phase_otel}"
      cat "$f" >> "${OTEL_LOG}"
    fi
  done
  rm -rf /tmp/agentic-ci-run.*
  return $rc
}

# Extract session metrics from OTEL data and produce BigQuery autodl.
# Usage: extract_session_metrics <issue_key> <phase>
extract_session_metrics() {
  local issue_key=$1 phase=$2

  if [ ! -f "${EXTRACT_METRICS}" ]; then
    echo "Warning: extract_metrics.py not found, skipping session metrics"
    return 0
  fi

  local phase_otel="/tmp/claude-${issue_key}-${phase}-otel.jsonl"
  if [ ! -f "$phase_otel" ] || [ ! -s "$phase_otel" ]; then
    echo "Warning: No OTEL data for ${phase}, skipping session metrics"
    return 0
  fi

  python3 "${EXTRACT_METRICS}" "$phase_otel" \
    "${ARTIFACT_DIR}/claude-${issue_key}-${phase}-session-metrics-autodl.json" \
    2>&1 || echo "Warning: Failed to extract session metrics for ${phase}"
}

# Generate domain-specific autodl for the jira_agent BigQuery table.
# Usage: generate_autodl <issue_key> <phase> <result> [pr_url] [session_id]
generate_autodl() {
  local issue_key=$1 phase=$2 result=$3
  local pr_url=${4:-} session_id=${5:-}
  local analyzed_at
  analyzed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local autodl_file="${ARTIFACT_DIR}/jira-agent-${issue_key}-${phase}-autodl.json"

  jq -n \
    --arg issue_key "$issue_key" \
    --arg phase "$phase" \
    --arg result "$result" \
    --arg pr_url "$pr_url" \
    --arg session_id "$session_id" \
    --arg analyzed_at "$analyzed_at" \
    --arg job_name "${JOB_NAME:-}" \
    --arg build_id "${BUILD_ID:-}" \
    '{
      table_name: "jira_agent",
      schema: {
        session_id: "string",
        agent: "string",
        phase: "string",
        issue_key: "string",
        pr_url: "string",
        result: "string",
        analyzed_at: "string",
        job_name: "string",
        build_id: "string"
      },
      schema_mapping: null,
      rows: [{
        session_id: $session_id,
        agent: "jira-agent",
        phase: $phase,
        issue_key: $issue_key,
        pr_url: $pr_url,
        result: $result,
        analyzed_at: $analyzed_at,
        job_name: $job_name,
        build_id: $build_id
      }],
      chunk_size: 0,
      expiration_days: 0,
      partition_column: ""
    }' > "$autodl_file"
  echo "Generated autodl: ${autodl_file}"
}

# Extract session_id from stream-json result line.
# Usage: get_session_id <json_file>
get_session_id() {
  local json_file=$1
  grep '"type":"result"' "$json_file" 2>/dev/null | head -1 | jq -r '.session_id // ""' 2>/dev/null || echo ""
}

# ── Output extraction ─────────────────────────────────────────────────────────

# Extract text, tool usage, and errors from Claude stream-json output.
# The report step expects "output" as the artifact prefix for Phase 1 (solve),
# so callers should pass the appropriate artifact_prefix.
#
# Usage: extract_claude_outputs <json_file> <issue_key> <artifact_prefix>
extract_claude_outputs() {
  local json_file=$1 issue_key=$2 prefix=$3
  jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' \
    "$json_file" > "${SHARED_DIR}/claude-${issue_key}-${prefix}-text.txt" 2>/dev/null || true
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' \
    "$json_file" 2>/dev/null | sort | uniq -c | sort -rn \
    > "${SHARED_DIR}/claude-${issue_key}-${prefix}-tools.txt" 2>/dev/null || true
  jq -r 'select(.type == "user") | .tool_use_result | select(type == "string") | select(startswith("Error:")) | gsub("\n"; "⏎")' \
    "$json_file" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/⏎/\n/g' \
    > "${SHARED_DIR}/claude-${issue_key}-${prefix}-errors.txt" 2>/dev/null || true
}

# Extract token usage metrics from the Claude stream-json result line.
# Token files always use the phase_name (solve/review/fix/pr) as the report step expects.
#
# Usage: extract_claude_tokens <json_file> <issue_key> <phase_name>
extract_claude_tokens() {
  local json_file=$1 issue_key=$2 phase=$3
  local default_json='{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}'
  grep '"type":"result"' "$json_file" \
    | head -1 \
    | jq '{
        total_cost_usd: (.total_cost_usd // 0),
        duration_ms: (.duration_ms // 0),
        num_turns: (.num_turns // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
        cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0),
        model_usage: (.modelUsage // {}),
        model: ((.modelUsage // {} | keys | first) // "unknown")
      }' > "${SHARED_DIR}/claude-${issue_key}-${phase}-tokens.json" 2>/dev/null \
    || echo "$default_json" > "${SHARED_DIR}/claude-${issue_key}-${phase}-tokens.json"
  echo "Phase ${phase} tokens: $(cat "${SHARED_DIR}/claude-${issue_key}-${phase}-tokens.json")"
}

# Record phase wall-clock duration to SHARED_DIR.
#
# Usage: record_phase_duration <issue_key> <phase_name> <start_epoch>
record_phase_duration() {
  local issue_key=$1 phase=$2 start=$3
  local end duration
  end=$(date +%s)
  duration=$((end - start))
  echo "Phase ${phase} duration: ${duration}s"
  echo "$duration" > "${SHARED_DIR}/claude-${issue_key}-${phase}-duration.txt"
}

# ── Phase runner ──────────────────────────────────────────────────────────────

# Run a Claude CLI phase: invoke claude via agentic-ci, extract outputs/tokens/duration/metrics.
#
# Usage: run_claude_phase <issue_key> <phase_name> <artifact_prefix> <prompt> <allowed_tools> <max_turns> [extra_claude_args...]
#   artifact_prefix: used for text/tools/errors filenames (e.g. "output" for solve, "review" for review)
#   extra args are passed directly to agentic-ci/claude CLI (e.g. --append-system-prompt "...")
#
# Sets global: PHASE_EXIT_CODE, PHASE_SESSION_ID
run_claude_phase() {
  local issue_key=$1 phase=$2 artifact_prefix=$3 prompt=$4 tools=$5 max_turns=$6
  shift 6

  local phase_start json_file log_file
  phase_start=$(date +%s)
  json_file="/tmp/claude-${issue_key}-${artifact_prefix}.json"
  log_file="/tmp/claude-${issue_key}-${artifact_prefix}.log"

  echo ""
  echo "=========================================="
  echo "Phase: ${phase} for ${issue_key}"
  echo "=========================================="

  set +e
  run_claude "$phase" "$issue_key" "$prompt" \
    --allowedTools "$tools" \
    --max-turns "$max_turns" \
    --effort max \
    "$@" \
    2> "$log_file" \
    | tee "$json_file"
  PHASE_EXIT_CODE=$?
  set -e

  extract_claude_outputs "$json_file" "$issue_key" "$artifact_prefix"
  extract_claude_tokens "$json_file" "$issue_key" "$phase"
  extract_session_metrics "$issue_key" "$phase"
  PHASE_SESSION_ID=$(get_session_id "$json_file")
  generate_autodl "$issue_key" "$phase" "$([ $PHASE_EXIT_CODE -eq 0 ] && echo success || echo failed)" "" "$PHASE_SESSION_ID"
  record_phase_duration "$issue_key" "$phase" "$phase_start"

  if [ $PHASE_EXIT_CODE -eq 0 ]; then
    echo "Phase ${phase} completed for ${issue_key}"
  else
    echo "Phase ${phase} failed for ${issue_key} (exit code: ${PHASE_EXIT_CODE})"
  fi
}

# ── Prompt builders ───────────────────────────────────────────────────────────

# Validate that the jira plugin is installed and solve.md is available.
# Sets: SKILL_CONTENT
# Exits with error if plugin is missing.
validate_jira_plugin() {
  local plugin_dir
  plugin_dir=$(claude plugin list --json 2>/dev/null \
    | jq -r '.[] | select(.id | test("^jira@")) | .installPath' 2>/dev/null) || true
  if [[ -z "$plugin_dir" ]] || [[ ! -f "${plugin_dir}/commands/solve.md" ]]; then
    echo "ERROR: jira plugin solve.md not found — is openshift-developer bundle installed?"
    exit 1
  fi
  SKILL_CONTENT=$(cat "${plugin_dir}/commands/solve.md")
  echo "Jira plugin validated (solve.md loaded)"
}

# Build the prompt for Phase 1 (solve).
# Arguments: <issue_key>
# Outputs: prints the prompt to stdout (fork context passed via --append-system-prompt)
build_solve_prompt() {
  local issue_key=$1
  echo "/jira:solve ${issue_key} origin --ci"
}

# Build the prompt for Phase 2 (review).
# Arguments: none
# Requires: REVIEW_LANGUAGE, REVIEW_PROFILE
# Outputs: prints the prompt to stdout
build_review_prompt() {
  local prompt="/code-review:pre-commit-review --language ${REVIEW_LANGUAGE}"
  if [ -n "$REVIEW_PROFILE" ]; then
    prompt="${prompt} --profile ${REVIEW_PROFILE}"
  fi
  echo "$prompt"
}

# Build the prompt for Phase 3 (fix review findings).
# Arguments: none (review findings passed via --append-system-prompt)
# Outputs: prints the prompt to stdout
build_fix_prompt() {
  echo "/openshift-developer:address-review-precommit"
}

# Build the prompt for Phase 4 (create PR).
# Arguments: <issue_key>
# Requires: JIRA_AGENT_UPSTREAM_REPO, FORK_ORG, BRANCH_NAME
# Outputs: prints the prompt to stdout
build_pr_prompt() {
  local issue_key=$1
  echo "/openshift-developer:create-pr ${issue_key} --upstream ${JIRA_AGENT_UPSTREAM_REPO} --head ${FORK_ORG}:${BRANCH_NAME}"
}

# Extract the PR URL from Claude's PR-phase output.
# Arguments: <issue_key>
# Requires: JIRA_AGENT_UPSTREAM_REPO
# Outputs: prints the URL to stdout (empty string if not found)
extract_pr_url() {
  local issue_key=$1
  grep -o "https://github.com/${JIRA_AGENT_UPSTREAM_REPO}/pull/[0-9]*" \
    "/tmp/claude-${issue_key}-pr.json" 2>/dev/null | head -1 || echo ""
}

# ── Pipeline ──────────────────────────────────────────────────────────────────

# Process a single Jira issue through the solve/review/fix/PR pipeline.
# Arguments: <issue_key> <issue_summary>
# Returns: 0 on success, 1 on failure
# Requires: SECURITY_PROMPT, SUBAGENT_PROMPT, REVIEW_LANGUAGE,
#           REVIEW_PROFILE, FORK_ORG, JIRA_AGENT_FORK_REPO, JIRA_AGENT_UPSTREAM_REPO,
#           STATE_FILE, JIRA_BASE_URL
process_single_issue() {
  local issue_key=$1 issue_summary=$2
  local timestamp pr_url=""

  echo ""
  echo "=========================================="
  echo "Processing: $issue_key"
  echo "Summary: $issue_summary"
  echo "=========================================="

  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  reset_to_main

  local fork_context="IMPORTANT: You are working in a fork (${JIRA_AGENT_FORK_REPO}). Git push is pre-configured to work with the fork. After creating commits on your feature branch, push the branch to origin. Do NOT create a Pull Request - the PR will be created in a subsequent automated step after code review. ${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"

  # Phase 1: Solve the issue
  run_claude_phase "$issue_key" "solve" "output" \
    "$(build_solve_prompt "$issue_key")" \
    "Bash Read Write Edit Grep Glob WebFetch Agent Skill Task" 300 \
    --append-system-prompt "$fork_context"

  if [ $PHASE_EXIT_CODE -ne 0 ]; then
    echo "Failed to process $issue_key"
    echo "Error output (last 20 lines):"
    tail -20 "/tmp/claude-${issue_key}-output.log"
    record_issue_result "$issue_key" "$timestamp" "" "FAILED"
    return 1
  fi

  check_branch_changes

  if [ "$HAS_CODE_CHANGES" != true ]; then
    echo "No code changes detected for $issue_key, skipping review and PR creation"
    postprocess_jira_issue "$issue_key" "true"
    record_issue_result "$issue_key" "$timestamp" "" "SUCCESS"
    return 0
  fi

  # Phase 2: Code review
  run_claude_phase "$issue_key" "review" "review" \
    "$(build_review_prompt)" \
    "Bash Read Grep Glob Task Agent Skill" 225 \
    --append-system-prompt "${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"

  # Phase 3: Fix review findings
  local review_findings=""
  if [ -f "${SHARED_DIR}/claude-${issue_key}-review-text.txt" ] && \
     [ -s "${SHARED_DIR}/claude-${issue_key}-review-text.txt" ]; then
    review_findings=$(cat "${SHARED_DIR}/claude-${issue_key}-review-text.txt")
  fi

  refresh_fork_token

  if [ -n "$review_findings" ]; then
    run_claude_phase "$issue_key" "fix" "fix" \
      "$(build_fix_prompt)" \
      "Bash Read Write Edit Grep Glob Agent Skill Task" 225 \
      --append-system-prompt "REVIEW FINDINGS:
${review_findings}

${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"
  else
    echo "No review findings to address, skipping Phase 3"
    record_phase_duration "$issue_key" "fix" "$(date +%s)"
  fi

  # Phase 4: Create PR
  refresh_all_tokens

  run_claude_phase "$issue_key" "pr-creation" "pr" \
    "$(build_pr_prompt "$issue_key")" \
    "Bash Read Grep Glob" 90 \
    --append-system-prompt "${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"

  local issue_success=true
  if [ $PHASE_EXIT_CODE -eq 0 ]; then
    pr_url=$(extract_pr_url "$issue_key")
    if [ -n "$pr_url" ]; then
      echo "PR created: $pr_url"
      generate_autodl "$issue_key" "pr-creation" "success" "$pr_url" "$PHASE_SESSION_ID"
    else
      echo "Phase 4 completed but no PR URL found in output"
      issue_success=false
    fi
  else
    issue_success=false
  fi

  # Post-PR: append report link, notify Slack
  if [ -n "$pr_url" ]; then
    local pr_num
    pr_num=$(echo "$pr_url" | grep -o '[0-9]*$' || true)
    if [ -n "$pr_num" ]; then
      append_report_link_to_pr "$pr_num" "$issue_key"
      send_slack_notification "$pr_url" "$pr_num"
    fi
  fi

  postprocess_jira_issue "$issue_key" "$issue_success"

  if [ "$issue_success" = true ]; then
    record_issue_result "$issue_key" "$timestamp" "$pr_url" "SUCCESS"
    return 0
  else
    record_issue_result "$issue_key" "$timestamp" "" "FAILED"
    return 1
  fi
}

HEREDOC_EOF

echo "claude-helpers.sh written to SHARED_DIR"
