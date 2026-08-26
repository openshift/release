#!/bin/bash
set -euo pipefail

cat > "${SHARED_DIR}/claude-helpers.sh" << 'HEREDOC_EOF'
#!/bin/bash
# Agent CLI helper functions for jira-agent phases.
#
# Usage:
#   source "${SHARED_DIR}/claude-helpers.sh"
#
# Functions:
#   run_agent                - Run the selected agent via agentic-ci for OTEL collection
#   extract_session_metrics  - Extract OTEL metrics for BigQuery autodl
#   generate_autodl          - Generate domain-specific BigQuery autodl JSON
#   get_session_id           - Extract session_id from stream-json output
#   extract_agent_outputs    - Extract text/tools/errors from agent JSONL
#   extract_agent_tokens     - Extract token usage metrics
#   record_phase_duration    - Record phase wall-clock time
#   run_agent_phase          - Run a full agent CLI phase with extraction
#   validate_jira_plugin     - Verify the Jira solve skill is installed
#   build_solve_prompt       - Build Phase 1 (solve) prompt
#   build_review_prompt      - Build Phase 2 (review) prompt
#   build_fix_prompt         - Build Phase 3 (fix) prompt
#   build_pr_prompt          - Build Phase 4 (PR) prompt
#   extract_pr_url           - Extract PR URL from Claude output
#   process_single_issue     - Run full solve/review/fix/PR pipeline

# ── OTEL / BigQuery telemetry ─────────────────────────────────────────────────

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"
if [ -z "${AGENT_MODEL:-}" ] || [ -z "${AGENT_HARNESS:-}" ] || [ -z "${AGENT_EFFORT:-}" ]; then
  echo "ERROR: Resolved agent configuration must be sourced before claude-helpers.sh"
  return 1
fi
export AGENT_MODEL AGENT_HARNESS AGENT_EFFORT

# Wrapper: run the selected agent via agentic-ci for native OTEL collection.
# Uses --no-streaming so stdout passes through raw for tee/reports.
# Filters to JSON lines only (agentic-ci log lines are stripped).
# Captures OTEL JSONL per invocation and appends to the consolidated log.
#
# Usage: run_agent <phase> <issue_key> <prompt> <output_file> [extra agent args...]
run_agent() {
  local phase=$1; shift
  local issue_key=$1; shift
  local prompt="$1"; shift
  local output_file="$1"; shift

  local phase_otel="/tmp/claude-${issue_key}-${phase}-otel.jsonl"
  local raw_output="/tmp/claude-${issue_key}-${phase}-raw.jsonl"
  local log_file="/tmp/claude-${issue_key}-${phase}.log"
  local harness_args=()

  case "$AGENT_HARNESS" in
    claude-code)
      harness_args=(--permission-mode default --verbose --output-format stream-json "$@")
      ;;
    codex)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --append-system-prompt)
            prompt="$2"$'\n\n'"$prompt"
            shift 2
            ;;
          --allowedTools|--max-turns|--output-format|--permission-mode)
            shift 2
            ;;
          --verbose)
            shift
            ;;
          --effort)
            AGENT_EFFORT="$2"
            shift 2
            ;;
          *)
            echo "ERROR: Unsupported Codex agent argument: $1"
            return 2
            ;;
        esac
      done
      harness_args=(-c "model_reasoning_effort=${AGENT_EFFORT}")
      ;;
    *)
      echo "ERROR: Unsupported agent harness: $AGENT_HARNESS"
      return 2
      ;;
  esac

  local rc=0
  agentic-ci run \
    --backend local \
    --harness "${AGENT_HARNESS}" \
    --model "${AGENT_MODEL}" \
    --workdir /tmp/project-repo \
    --no-streaming \
    "${prompt}" \
    -- \
    "${harness_args[@]}" \
    > "$raw_output" 2>"$log_file" \
    || rc=$?

  grep '^{' "$raw_output" > "$output_file" || true

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

  if [ "$AGENT_HARNESS" != "claude-code" ]; then
    echo "Info: Claude OTEL session metrics are not supported for ${AGENT_HARNESS}; using agent JSONL token metrics"
    return 0
  fi

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

# Extract session_id from the agent JSONL output.
# Codex thread IDs are hashed before they are written to published artifacts.
# Usage: get_session_id <json_file>
get_session_id() {
  local json_file=$1
  if [ "$AGENT_HARNESS" = "codex" ]; then
    local thread_id
    thread_id=$(jq -r 'select(.type == "thread.started") | .thread_id // ""' "$json_file" 2>/dev/null | head -1 || echo "")
    if [ -n "$thread_id" ]; then
      printf '%s' "$thread_id" | sha256sum | cut -d' ' -f1
    fi
  else
    grep '"type":"result"' "$json_file" 2>/dev/null | head -1 | jq -r '.session_id // ""' 2>/dev/null || echo ""
  fi
}

# ── Output extraction ─────────────────────────────────────────────────────────

# Extract text, tool usage, and errors from agent JSONL output.
# The report step expects "output" as the artifact prefix for Phase 1 (solve),
# so callers should pass the appropriate artifact_prefix.
#
# Usage: extract_agent_outputs <json_file> <issue_key> <artifact_prefix>
extract_agent_outputs() {
  local json_file=$1 issue_key=$2 prefix=$3
  if [ "$AGENT_HARNESS" = "codex" ]; then
    jq -r 'select(.type == "item.completed" and .item.type == "agent_message") | .item.text // empty' \
      "$json_file" > "${SHARED_DIR}/claude-${issue_key}-${prefix}-text.txt" 2>/dev/null || true
    {
      jq -r 'select(.type == "item.completed" and .item.type == "command_execution") | "Shell command"' "$json_file"
      jq -r 'select(.type == "item.completed" and .item.type == "mcp_tool_call") | "MCP tool call"' "$json_file"
      jq -r 'select(.type == "item.completed" and .item.type == "web_search") | "Web search"' "$json_file"
      jq -r 'select(.type == "item.completed" and .item.type == "file_change") | "File change"' "$json_file"
    } 2>/dev/null | sed '/^[[:space:]]*$/d' | sort | uniq -c | sort -rn \
      > "${SHARED_DIR}/claude-${issue_key}-${prefix}-tools.txt" 2>/dev/null || true
    {
      jq -r 'select(.type == "error") | "Codex error"' "$json_file"
      jq -r 'select(.type == "turn.failed") | "Codex turn failed"' "$json_file"
      jq -r 'select(.type == "item.completed" and .item.type == "mcp_tool_call" and (.item.error != null or .item.status == "failed" or .item.status == "error")) | "MCP tool call failed"' "$json_file"
    } 2>/dev/null | sed '/^[[:space:]]*$/d' | sort | uniq -c | sort -rn \
      > "${SHARED_DIR}/claude-${issue_key}-${prefix}-errors.txt" 2>/dev/null || true
  else
    jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' \
      "$json_file" > "${SHARED_DIR}/claude-${issue_key}-${prefix}-text.txt" 2>/dev/null || true
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' \
      "$json_file" 2>/dev/null | sort | uniq -c | sort -rn \
      > "${SHARED_DIR}/claude-${issue_key}-${prefix}-tools.txt" 2>/dev/null || true
    jq -r 'select(.type == "user") | .tool_use_result | select(type == "string") | select(startswith("Error:")) | gsub("\n"; "⏎")' \
      "$json_file" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/⏎/\n/g' \
      > "${SHARED_DIR}/claude-${issue_key}-${prefix}-errors.txt" 2>/dev/null || true
  fi
}

# Extract token usage metrics from the selected agent's JSONL output.
# Token files always use the phase_name (solve/review/fix/pr) as the report step expects.
#
# Usage: extract_agent_tokens <json_file> <issue_key> <phase_name> [duration_ms]
extract_agent_tokens() {
  local json_file=$1 issue_key=$2 phase=$3 duration_ms=${4:-0}
  local default_json='{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}'
  if [ "$AGENT_HARNESS" = "codex" ]; then
    jq -s --arg model "$AGENT_MODEL" --argjson duration_ms "$duration_ms" '
      ([.[] | select(.type == "turn.completed") | .usage // {}]) as $usages |
      ($usages | map(.input_tokens // 0) | add // 0) as $input_tokens |
      ($usages | map(.output_tokens // 0) | add // 0) as $output_tokens |
      ($usages | map(.cached_input_tokens // 0) | add // 0) as $cache_read_tokens |
      ($usages | map(.cache_write_input_tokens // 0) | add // 0) as $cache_creation_tokens |
      {
        total_cost_usd: null,
        duration_ms: $duration_ms,
        num_turns: ($usages | length),
        input_tokens: $input_tokens,
        output_tokens: $output_tokens,
        cache_read_input_tokens: $cache_read_tokens,
        cache_creation_input_tokens: $cache_creation_tokens,
        model_usage: {
          ($model): {
            inputTokens: $input_tokens,
            outputTokens: $output_tokens,
            cacheReadInputTokens: $cache_read_tokens,
            cacheCreationInputTokens: $cache_creation_tokens
          }
        },
        model: $model
      }' "$json_file" > "${SHARED_DIR}/claude-${issue_key}-${phase}-tokens.json" 2>/dev/null \
      || echo '{"total_cost_usd":null,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}' > "${SHARED_DIR}/claude-${issue_key}-${phase}-tokens.json"
  else
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
  fi
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

# Run an agent CLI phase via agentic-ci, extracting outputs/tokens/duration/metrics.
#
# Usage: run_agent_phase <issue_key> <phase_name> <artifact_prefix> <prompt> <allowed_tools> <max_turns> [extra_agent_args...]
#   artifact_prefix: used for text/tools/errors filenames (e.g. "output" for solve, "review" for review)
#   extra args are passed to the selected agent (e.g. --append-system-prompt "...").
#
# Sets global: PHASE_EXIT_CODE, PHASE_SESSION_ID
run_agent_phase() {
  local issue_key=$1 phase=$2 artifact_prefix=$3 prompt=$4 tools=$5 max_turns=$6
  shift 6

  local phase_start json_file
  phase_start=$(date +%s)
  json_file="/tmp/claude-${issue_key}-${artifact_prefix}.json"

  echo ""
  echo "=========================================="
  echo "Phase: ${phase} for ${issue_key}"
  echo "=========================================="

  PHASE_EXIT_CODE=0
  if [ "$AGENT_HARNESS" = "codex" ]; then
    run_agent "$phase" "$issue_key" "$prompt" "$json_file" \
      --effort "$AGENT_EFFORT" \
      "$@" \
      || PHASE_EXIT_CODE=$?
  else
    run_agent "$phase" "$issue_key" "$prompt" "$json_file" \
      --allowedTools "$tools" \
      --max-turns "$max_turns" \
      --effort "$AGENT_EFFORT" \
      "$@" \
      || PHASE_EXIT_CODE=$?
  fi

  extract_agent_outputs "$json_file" "$issue_key" "$artifact_prefix"
  record_phase_duration "$issue_key" "$phase" "$phase_start"
  extract_agent_tokens "$json_file" "$issue_key" "$phase" \
    "$(( $(cat "${SHARED_DIR}/claude-${issue_key}-${phase}-duration.txt") * 1000 ))"
  extract_session_metrics "$issue_key" "$phase"
  PHASE_SESSION_ID=$(get_session_id "$json_file")
  generate_autodl "$issue_key" "$phase" "$([ $PHASE_EXIT_CODE -eq 0 ] && echo success || echo failed)" "" "$PHASE_SESSION_ID"

  if [ $PHASE_EXIT_CODE -eq 0 ]; then
    echo "Phase ${phase} completed for ${issue_key}"
  else
    echo "Phase ${phase} failed for ${issue_key} (exit code: ${PHASE_EXIT_CODE})"
  fi
}

# ── Prompt builders ───────────────────────────────────────────────────────────

# Validate that the selected harness has the openshift-developer plugin and jira-solve skill.
# Exits with error if plugin is missing.
validate_jira_plugin() {
  if [ "$AGENT_HARNESS" = "codex" ]; then
    local plugin_json plugin_version codex_home plugin_dir
    if ! plugin_json=$(codex plugin list --json --marketplace ai-helpers 2>/dev/null); then
      echo "ERROR: Unable to inspect installed Codex plugins"
      exit 1
    fi
    if ! plugin_version=$(printf '%s\n' "$plugin_json" | jq -er '
      first(
        .installed[]
        | select(.pluginId == "openshift-developer@ai-helpers" and .installed == true and .enabled == true)
        | .version // empty
      )
    '); then
      echo "ERROR: openshift-developer plugin is not installed and enabled for Codex"
      exit 1
    fi
    codex_home="${CODEX_HOME:-${HOME}/.codex}"
    plugin_dir="${codex_home}/plugins/cache/ai-helpers/openshift-developer/${plugin_version}"
    if [ ! -f "${plugin_dir}/skills/jira-solve/SKILL.md" ]; then
      echo "ERROR: Installed Codex openshift-developer plugin lacks the jira-solve skill"
      exit 1
    fi
    echo "openshift-developer plugin validated for Codex"
    return
  fi

  local plugin_dir
  plugin_dir=$(claude plugin list --json 2>/dev/null \
    | jq -r '.[] | select(.id | test("^openshift-developer@")) | .installPath' 2>/dev/null) || true
  if [[ -z "$plugin_dir" ]] || [[ ! -f "${plugin_dir}/skills/jira-solve/SKILL.md" ]]; then
    echo "ERROR: openshift-developer plugin jira-solve skill not found — is openshift-developer bundle installed?"
    exit 1
  fi
  echo "openshift-developer plugin validated for Claude Code"
}

# Build the prompt for Phase 1 (solve).
# Arguments: <issue_key>
# Outputs: prints the prompt to stdout (fork context passed via --append-system-prompt)
build_solve_prompt() {
  local issue_key=$1
  echo "/openshift-developer:jira-solve ${issue_key} origin --ci"
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

# Extract the PR URL from the PR-phase output.
# Arguments: <issue_key>
# Requires: JIRA_AGENT_UPSTREAM_REPO
# Outputs: prints the URL to stdout (empty string if not found)
extract_pr_url() {
  local issue_key=$1
  if [ "$AGENT_HARNESS" = "codex" ]; then
    jq -r 'select(.type == "item.completed" and .item.type == "agent_message") | .item.text // empty' \
      "/tmp/claude-${issue_key}-pr.json" 2>/dev/null \
      | grep -o "https://github.com/${JIRA_AGENT_UPSTREAM_REPO}/pull/[0-9]*" \
      | tail -1 || true
  else
    grep -o "https://github.com/${JIRA_AGENT_UPSTREAM_REPO}/pull/[0-9]*" \
      "/tmp/claude-${issue_key}-pr.json" 2>/dev/null | tail -1 || true
  fi
}

# Validate that the extracted URL is the open PR created for this issue.
# Arguments: <issue_key> <pr_url>
# Requires: JIRA_AGENT_UPSTREAM_REPO, JIRA_AGENT_FORK_REPO, BRANCH_NAME, DEFAULT_BRANCH
validate_pr_url() {
  local issue_key=$1 pr_url=$2
  local pr_num pr_data
  pr_num="${pr_url##*/}"

  if [[ ! "$pr_num" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid PR URL for ${issue_key}"
    return 1
  fi

  if ! pr_data=$(gh api "repos/${JIRA_AGENT_UPSTREAM_REPO}/pulls/${pr_num}" 2>/dev/null); then
    echo "ERROR: Unable to inspect PR ${pr_url} for ${issue_key}"
    return 1
  fi

  if ! jq -e \
    --arg issue_key "$issue_key" \
    --arg expected_branch "$BRANCH_NAME" \
    --arg expected_fork "$JIRA_AGENT_FORK_REPO" \
    --arg expected_upstream "$JIRA_AGENT_UPSTREAM_REPO" \
    --arg expected_base "$DEFAULT_BRANCH" \
    '(
      .state == "open"
      and .head.ref == $expected_branch
      and .head.repo.full_name == $expected_fork
      and .base.ref == $expected_base
      and .base.repo.full_name == $expected_upstream
      and (((.title // "") + "\n" + (.body // "")) | contains($issue_key))
    )' <<< "$pr_data" >/dev/null; then
    echo "ERROR: PR ${pr_url} does not match the open ${issue_key} branch"
    return 1
  fi
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
  run_agent_phase "$issue_key" "solve" "output" \
    "$(build_solve_prompt "$issue_key")" \
    "Bash Read Write Edit Grep Glob WebFetch Agent Skill Task LSP mcp__plugin_golang_gopls__*" 300 \
    --append-system-prompt "$fork_context"

  if [ $PHASE_EXIT_CODE -ne 0 ]; then
    echo "Failed to process $issue_key (solve exit code: $PHASE_EXIT_CODE)"
    echo "Error output (last 20 lines):"
    tail -20 "/tmp/claude-${issue_key}-solve.log" 2>/dev/null || echo "(no log file)"
    record_issue_result "$issue_key" "$timestamp" "" "FAILED"
    return 1
  fi

  # Phase 1 can take 35-43 min; refresh token before push (tokens expire after 60 min)
  refresh_fork_token

  check_branch_changes

  if [ "$HAS_CODE_CHANGES" != true ]; then
    echo "No code changes detected for $issue_key, skipping review and PR creation"
    postprocess_jira_issue "$issue_key" "true"
    record_issue_result "$issue_key" "$timestamp" "" "SUCCESS"
    return 0
  fi

  # Phase 2: Code review
  run_agent_phase "$issue_key" "review" "review" \
    "$(build_review_prompt)" \
    "Bash Read Grep Glob Task Agent Skill LSP mcp__plugin_golang_gopls__*" 225 \
    --append-system-prompt "${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"

  # Phase 3: Fix review findings
  local review_findings=""
  if [ -f "${SHARED_DIR}/claude-${issue_key}-review-text.txt" ] && \
     [ -s "${SHARED_DIR}/claude-${issue_key}-review-text.txt" ]; then
    review_findings=$(cat "${SHARED_DIR}/claude-${issue_key}-review-text.txt")
  fi

  refresh_fork_token

  if [ -n "$review_findings" ]; then
    run_agent_phase "$issue_key" "fix" "fix" \
      "$(build_fix_prompt)" \
      "Bash Read Write Edit Grep Glob Agent Skill Task LSP mcp__plugin_golang_gopls__*" 225 \
      --append-system-prompt "REVIEW FINDINGS:
${review_findings}

${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"
  else
    echo "No review findings to address, skipping Phase 3"
    record_phase_duration "$issue_key" "fix" "$(date +%s)"
  fi

  # Phase 4: Create PR
  refresh_all_tokens

  run_agent_phase "$issue_key" "pr-creation" "pr" \
    "$(build_pr_prompt "$issue_key")" \
    "Bash Read Grep Glob" 90 \
    --append-system-prompt "${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"

  if [ $PHASE_EXIT_CODE -eq 0 ]; then
    pr_url=$(extract_pr_url "$issue_key")
    if [ -n "$pr_url" ] && validate_pr_url "$issue_key" "$pr_url"; then
      echo "PR created: $pr_url"
      generate_autodl "$issue_key" "pr-creation" "success" "$pr_url" "$PHASE_SESSION_ID"
    else
      echo "ERROR: Phase 4 completed without a valid open PR for $issue_key"
      pr_url=""
      PHASE_EXIT_CODE=1
    fi
  fi

  # Only mark the issue processed after a successful pipeline or a no-change result.
  postprocess_jira_issue "$issue_key" "$([ $PHASE_EXIT_CODE -eq 0 ] && echo true || echo false)"

  # Post-PR: append report link, notify Slack
  if [ -n "$pr_url" ]; then
    local pr_num
    pr_num=$(echo "$pr_url" | grep -o '[0-9]*$' || true)
    if [ -n "$pr_num" ]; then
      append_report_link_to_pr "$pr_num" "$issue_key"
      send_slack_notification "$pr_url" "$pr_num"
    fi
  fi

  if [ $PHASE_EXIT_CODE -eq 0 ]; then
    record_issue_result "$issue_key" "$timestamp" "${pr_url:-}" "SUCCESS"
    return 0
  else
    record_issue_result "$issue_key" "$timestamp" "" "FAILED"
    return 1
  fi
}

HEREDOC_EOF

echo "claude-helpers.sh written to SHARED_DIR"
