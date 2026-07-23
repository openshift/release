#!/bin/bash
set -euo pipefail

echo "=== Review Agent Process ==="

# Auth mode: "app" (GitHub App, default) or "pat" (classic PAT)
REVIEW_AGENT_AUTH_MODE="${REVIEW_AGENT_AUTH_MODE:-app}"
REVIEW_AGENT_PAT_KEY="${REVIEW_AGENT_PAT_KEY:-gh-pat}"
REVIEW_AGENT_FORK_ORG="${REVIEW_AGENT_FORK_ORG:-}"

# Validate required env vars
if [[ "$REVIEW_AGENT_AUTH_MODE" == "app" ]] && [[ -z "${REVIEW_AGENT_FORK_REPO:-}" ]]; then
  echo "ERROR: REVIEW_AGENT_FORK_REPO is required in App auth mode (e.g. https://github.com/hypershift-community/hypershift)"
  exit 1
fi
if [[ "$REVIEW_AGENT_AUTH_MODE" == "pat" ]] && [[ -z "$REVIEW_AGENT_FORK_ORG" ]]; then
  echo "ERROR: REVIEW_AGENT_FORK_ORG is required in PAT auth mode"
  exit 1
fi
if [[ -z "${REVIEW_AGENT_UPSTREAM_REPO:-}" ]]; then
  echo "ERROR: REVIEW_AGENT_UPSTREAM_REPO is required (e.g. openshift/hypershift)"
  exit 1
fi

# In PAT mode, derive fork repo from FORK_ORG + upstream repo name if not set
if [[ "$REVIEW_AGENT_AUTH_MODE" == "pat" ]] && [[ -z "${REVIEW_AGENT_FORK_REPO:-}" ]]; then
  REVIEW_AGENT_FORK_REPO="https://github.com/${REVIEW_AGENT_FORK_ORG}/${REVIEW_AGENT_UPSTREAM_REPO#*/}"
fi

echo "Configuration: AUTH_MODE=$REVIEW_AGENT_AUTH_MODE"

# Derive clone directory from fork repo URL
CLONE_DIR="/tmp/$(basename "$REVIEW_AGENT_FORK_REPO")"

# Apply Gangway API overrides (MULTISTAGE_PARAM_OVERRIDE_* prefix)
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_REVIEW_AGENT_TARGET_PR:-}" ]]; then
  echo "Applying Gangway override: REVIEW_AGENT_TARGET_PR=${MULTISTAGE_PARAM_OVERRIDE_REVIEW_AGENT_TARGET_PR}"
  export REVIEW_AGENT_TARGET_PR="${MULTISTAGE_PARAM_OVERRIDE_REVIEW_AGENT_TARGET_PR}"
fi

# Determine which PR to process
PR_NUMBER="${REVIEW_AGENT_TARGET_PR:-${PULL_NUMBER:-}}"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: No PR number specified. Set REVIEW_AGENT_TARGET_PR via gangway or PULL_NUMBER via presubmit."
  exit 1
fi
echo "Processing PR #$PR_NUMBER"

# State file for sharing results with report step
STATE_FILE="${SHARED_DIR}/processed-prs.txt"

# Clone the fork repo
echo "Cloning repository from ${REVIEW_AGENT_FORK_REPO}..."
git clone "${REVIEW_AGENT_FORK_REPO}" "${CLONE_DIR}"

# Install tool dependencies
echo "Installing tool dependencies..."
GOFLAGS="" go install golang.org/x/tools/gopls@v0.21.0
python3.9 -m ensurepip --user 2>/dev/null || true
python3.9 -m pip install --user pre-commit 2>&1 | tail -1
export PATH="${GOPATH:-$HOME/go}/bin:$HOME/.local/bin:$PATH"
# 20min bash timeout so pre-commit/pre-push hooks (make verify, make test) have time to complete
export BASH_DEFAULT_TIMEOUT_MS=1200000
export BASH_MAX_TIMEOUT_MS=1200000

# Force HTTPS for all github.com git operations (plugin install defaults to SSH which lacks host keys in CI)
git config --global url."https://github.com/".insteadOf "git@github.com:"

# Install the openshift-developer plugin (bundles jira, ci, golang, prodsec-skills, git)
echo "Installing Claude Code plugins..."
claude plugin marketplace add openshift-eng/ai-helpers
claude plugin marketplace add RedHatProductSecurity/prodsec-skills
claude plugin install openshift-developer@ai-helpers
claude plugin install prow-agent@ai-helpers

cd "${CLONE_DIR}"

# Configure git
git config user.name "OpenShift CI Bot"
git config user.email "ci-bot@redhat.com"

# Add upstream remote for PR operations
git remote add upstream "https://github.com/${REVIEW_AGENT_UPSTREAM_REPO}.git"

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"

if [[ "$REVIEW_AGENT_AUTH_MODE" == "pat" ]]; then
  # PAT mode: single token for push + PR operations
  echo "Loading GitHub PAT credentials..."
  PAT_FILE="${GITHUB_APP_CREDS_DIR}/${REVIEW_AGENT_PAT_KEY}"
  if [ ! -f "$PAT_FILE" ]; then
    echo "ERROR: PAT file not found: $PAT_FILE"
    ls -la "${GITHUB_APP_CREDS_DIR}/" || echo "Directory does not exist"
    exit 1
  fi
  [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
  set +x
  GITHUB_TOKEN_PAT=$(cat "$PAT_FILE")
  if [ -z "$GITHUB_TOKEN_PAT" ]; then
    echo "ERROR: PAT file is empty: $PAT_FILE"
    $_was_tracing && set -x || true
    exit 1
  fi
  git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_PAT}; }; f"
  export GITHUB_TOKEN="$GITHUB_TOKEN_PAT"
  echo "PAT configured for git and GitHub CLI"
  $_was_tracing && set -x || true

  # Ensure the fork exists (auto-fork if needed)
  FORK_REPO_NAME="${REVIEW_AGENT_UPSTREAM_REPO#*/}"
  echo "Checking if fork ${REVIEW_AGENT_FORK_ORG}/${FORK_REPO_NAME} exists..."
  FORK_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REVIEW_AGENT_FORK_ORG}/${FORK_REPO_NAME}")
  if [ "$FORK_HTTP_CODE" != "200" ]; then
    echo "Fork not found (HTTP ${FORK_HTTP_CODE}). Creating fork of ${REVIEW_AGENT_UPSTREAM_REPO}..."
    FORK_RESPONSE=$(curl -s -X POST \
      --connect-timeout 10 --max-time 30 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${REVIEW_AGENT_UPSTREAM_REPO}/forks" \
      -d '{"default_branch_only":true}')
    FORK_FULL_NAME=$(echo "$FORK_RESPONSE" | jq -r '.full_name // empty' 2>/dev/null)
    if [ -z "$FORK_FULL_NAME" ]; then
      echo "ERROR: Failed to create fork. API response:"
      echo "$FORK_RESPONSE" | head -20
      exit 1
    fi
    echo "Fork creation initiated: ${FORK_FULL_NAME}"
    # Poll until ready
    WAITED=0
    while [ $WAITED -lt 120 ]; do
      FORK_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REVIEW_AGENT_FORK_ORG}/${FORK_REPO_NAME}")
      [ "$FORK_HTTP_CODE" = "200" ] && break
      echo "Waiting for fork to be ready... (${WAITED}s/120s)"
      sleep 10
      WAITED=$((WAITED + 10))
    done
    if [ "$FORK_HTTP_CODE" != "200" ]; then
      echo "ERROR: Fork not ready after 120s"
      exit 1
    fi
    echo "Fork ${REVIEW_AGENT_FORK_ORG}/${FORK_REPO_NAME} is ready"
  else
    echo "Fork ${REVIEW_AGENT_FORK_ORG}/${FORK_REPO_NAME} already exists"
  fi
else
  # App mode: separate fork/upstream tokens
  echo "Loading GitHub App auth library..."
  if [ ! -f "${SHARED_DIR}/github-app-auth.sh" ]; then
    echo "ERROR: github-app-auth.sh not found in SHARED_DIR."
    echo "Ensure jira-agent-github-app-auth runs as a pre step."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/github-app-auth.sh"

  INSTALLATION_ID_FORK_FILE="${GITHUB_APP_CREDS_DIR}/installation-id"
  INSTALLATION_ID_UPSTREAM_FILE="${GITHUB_APP_CREDS_DIR}/o-h-installation-id"

  if [ ! -f "$INSTALLATION_ID_FORK_FILE" ] || [ ! -f "$INSTALLATION_ID_UPSTREAM_FILE" ]; then
    echo "GitHub App credentials not yet available in ${GITHUB_APP_CREDS_DIR}"
    echo "Available files:"
    ls -la "${GITHUB_APP_CREDS_DIR}/" || echo "Directory does not exist"
    echo "ERROR: Required credentials are missing. Re-run once secrets are synced."
    exit 1
  fi

  INSTALLATION_ID_FORK=$(cat "$INSTALLATION_ID_FORK_FILE")
  INSTALLATION_ID_UPSTREAM=$(cat "$INSTALLATION_ID_UPSTREAM_FILE")

  echo "Generating GitHub App token for fork..."
  GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
  if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
    echo "ERROR: Failed to generate GitHub App token for fork"
    exit 1
  fi
  echo "Fork token generated successfully"

  echo "Generating GitHub App token for upstream..."
  GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
  if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
    echo "ERROR: Failed to generate GitHub App token for upstream"
    exit 1
  fi
  echo "Upstream token generated successfully"

  # Disable tracing due to token handling
  [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
  set +x
  git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"
  export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
  echo "GitHub App tokens configured successfully"
  $_was_tracing && set -x || true
fi

# TODO: Stronger sandboxing (container-level isolation, ai-guardian, PreToolUse hooks)
# tracked in https://redhat.atlassian.net/browse/CNTRLPLANE-3750
DISALLOWED_TOOLS=(
  "Bash(git config*credential*)"
  "Bash(git config*--list*)"
  "Bash(git config*-l*)"
  "Bash(echo*GITHUB_TOKEN*)"
  "Bash(env*)"
  "Bash(printenv*)"
  "Bash(cat*claude-code-service-account*)"
)


# OTEL / BigQuery telemetry support
EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

# Derive repo name for telemetry
REPO_NAME="${REVIEW_AGENT_UPSTREAM_REPO}"

# Wrapper: run claude via agentic-ci for native OTEL collection
run_claude() {
  local phase=$1; shift
  local pr_number=$1; shift
  local prompt="$1"; shift
  local output_file="$1"; shift

  local phase_otel="/tmp/claude-${pr_number}-${phase}-otel.jsonl"
  local raw_output="/tmp/claude-${pr_number}-${phase}-raw.jsonl"
  local log_file="/tmp/claude-${pr_number}-${phase}.log"

  local rc=0
  agentic-ci run \
    --backend local \
    --harness claude-code \
    --model "${CLAUDE_MODEL}" \
    --workdir "${CLONE_DIR}" \
    --no-streaming \
    "${prompt}" \
    -- \
    --permission-mode default \
    --verbose \
    --output-format stream-json \
    "$@" \
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

extract_session_metrics() {
  local pr_number=$1
  local phase=$2

  if [ ! -f "${EXTRACT_METRICS}" ]; then
    echo "Warning: extract_metrics.py not found, skipping session metrics"
    return 0
  fi

  local phase_otel="/tmp/claude-${pr_number}-${phase}-otel.jsonl"
  if [ ! -f "$phase_otel" ] || [ ! -s "$phase_otel" ]; then
    echo "Warning: No OTEL data for ${phase}, skipping session metrics"
    return 0
  fi

  python3 "${EXTRACT_METRICS}" "$phase_otel" \
    "${ARTIFACT_DIR}/claude-${pr_number}-${phase}-session-metrics-autodl.json" \
    2>&1 || echo "Warning: Failed to extract session metrics for ${phase}"
}

get_session_id() {
  local json_file=$1
  grep '"type":"result"' "$json_file" 2>/dev/null | head -1 | jq -r '.session_id // ""' 2>/dev/null || echo ""
}

generate_autodl() {
  local pr_number=$1
  local result=$2
  local session_id=${3:-}
  local analyzed_at
  analyzed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local autodl_file="${ARTIFACT_DIR}/review-agent-pr-${pr_number}-autodl.json"

  jq -n \
    --arg pr_number "$pr_number" \
    --arg result "$result" \
    --arg session_id "$session_id" \
    --arg analyzed_at "$analyzed_at" \
    --arg job_name "${JOB_NAME:-}" \
    --arg build_id "${BUILD_ID:-}" \
    --arg repo "$REPO_NAME" \
    '{
      table_name: "address_review_agent",
      schema: {
        session_id: "string",
        agent: "string",
        pr_number: "string",
        result: "string",
        analyzed_at: "string",
        job_name: "string",
        build_id: "string",
        repo: "string"
      },
      schema_mapping: null,
      rows: [{
        session_id: $session_id,
        agent: "address-review",
        pr_number: $pr_number,
        result: $result,
        analyzed_at: $analyzed_at,
        job_name: $job_name,
        build_id: $build_id,
        repo: $repo
      }],
      chunk_size: 0,
      expiration_days: 0,
      partition_column: ""
    }' > "$autodl_file"
  echo "Generated autodl: ${autodl_file}"
}

# Helper: extract token usage from stream-json output and save to SHARED_DIR
extract_tokens() {
  local JSON_FILE=$1
  local OUTPUT_FILE=$2

  grep '"type":"result"' "$JSON_FILE" \
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
      }' > "$OUTPUT_FILE" 2>/dev/null \
    || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}' > "$OUTPUT_FILE"
}

# Helper: extract text, tool usage, and errors from stream-json output
extract_artifacts() {
  local JSON_FILE=$1
  local PREFIX=$2

  jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "$JSON_FILE" > "${SHARED_DIR}/${PREFIX}-text.txt" 2>/dev/null || true
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "$JSON_FILE" 2>/dev/null | sort | uniq -c | sort -rn > "${SHARED_DIR}/${PREFIX}-tools.txt" 2>/dev/null || true
  jq -r 'select(.type == "user") | .tool_use_result | select(type == "string") | select(startswith("Error:")) | gsub("\n"; "⏎")' "$JSON_FILE" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/⏎/\n/g' > "${SHARED_DIR}/${PREFIX}-errors.txt" 2>/dev/null || true
}

# Checkout the PR branch
echo "Fetching PR #$PR_NUMBER details..."
PR_INFO=$(gh pr view "$PR_NUMBER" \
  --repo "${REVIEW_AGENT_UPSTREAM_REPO}" \
  --json number,title,headRefName \
  --jq '"\(.number) \(.headRefName) \(.title)"' 2>/dev/null || echo "")

if [ -z "$PR_INFO" ]; then
  echo "ERROR: PR #$PR_NUMBER not found or not accessible"
  exit 1
fi

BRANCH_NAME=$(echo "$PR_INFO" | awk '{print $2}')
PR_TITLE=$(echo "$PR_INFO" | cut -d' ' -f3-)

echo "Branch: $BRANCH_NAME"
echo "Title: $PR_TITLE"

echo "Checking out branch: $BRANCH_NAME"
git fetch origin "$BRANCH_NAME"
git checkout -B "$BRANCH_NAME" "origin/$BRANCH_NAME"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Run /openshift-developer:address-review-pr skill
echo ""
echo "=========================================="
echo "Addressing review comments for PR #$PR_NUMBER"
echo "=========================================="

PHASE1_START=$(date +%s)

EXIT_CODE=0
run_claude "address-review" "$PR_NUMBER" "/openshift-developer:address-review-pr $PR_NUMBER --ci" "/tmp/claude-pr-${PR_NUMBER}-output.json" \
  --append-system-prompt "You are addressing review comments on PR #$PR_NUMBER in ${REVIEW_AGENT_UPSTREAM_REPO}. The PR was created from the $(basename "$REVIEW_AGENT_FORK_REPO") fork." \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch Agent Skill Task LSP mcp__plugin_golang_gopls__*" \
  --disallowedTools "${DISALLOWED_TOOLS[@]}" \
  --max-turns 200 \
  --effort max \
  || EXIT_CODE=$?

# Save raw output to ARTIFACT_DIR for debugging
if [ -f "/tmp/claude-pr-${PR_NUMBER}-output.json" ]; then
  cp "/tmp/claude-pr-${PR_NUMBER}-output.json" "${ARTIFACT_DIR}/claude-pr-${PR_NUMBER}-output.json" 2>/dev/null || true
fi

# Extract artifacts for the report step
extract_artifacts "/tmp/claude-pr-${PR_NUMBER}-output.json" "claude-pr-${PR_NUMBER}-review"
extract_session_metrics "$PR_NUMBER" "address-review"
extract_tokens "/tmp/claude-pr-${PR_NUMBER}-output.json" "${SHARED_DIR}/claude-pr-${PR_NUMBER}-review-tokens.json"
echo "Token usage: $(cat "${SHARED_DIR}/claude-pr-${PR_NUMBER}-review-tokens.json")"
REVIEW_SESSION_ID=$(get_session_id "/tmp/claude-pr-${PR_NUMBER}-output.json")
generate_autodl "$PR_NUMBER" "$([ $EXIT_CODE -eq 0 ] && echo success || echo failed)" "$REVIEW_SESSION_ID"

PHASE_END=$(date +%s)
PHASE_DURATION=$((PHASE_END - PHASE1_START))
echo "Duration: ${PHASE_DURATION}s"
echo "$PHASE_DURATION" > "${SHARED_DIR}/claude-pr-${PR_NUMBER}-review-duration.txt"

if [ $EXIT_CODE -eq 0 ]; then
  echo "✅ Review comments addressed for PR #$PR_NUMBER"
  echo "$PR_NUMBER $TIMESTAMP SUCCESS" >> "$STATE_FILE"
else
  echo "❌ Failed to address review comments for PR #$PR_NUMBER (exit code: $EXIT_CODE)"
  echo "Error output (last 20 lines):"
  tail -20 "/tmp/claude-pr-${PR_NUMBER}-output.log"
  echo "$PR_NUMBER $TIMESTAMP FAILED" >> "$STATE_FILE"
fi

# Generate conversation transcript HTML from stream-json output
echo "Generating conversation transcript..."
python3 - "$STATE_FILE" "$ARTIFACT_DIR" << 'TRANSCRIPT_PY'
import json, html, sys, os

state_file = sys.argv[1]
artifact_dir = sys.argv[2]
output_file = os.path.join(artifact_dir, "review-agent-transcript.html")

def parse_stream_json(path):
    blocks = []
    cost = turns = inp = outp = duration = 0
    model = session = "unknown"
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        t = m.get("type", "")
        if t == "system" and m.get("subtype") == "init":
            model = m.get("model", "unknown")
            session = m.get("session_id", "unknown")
        if t == "result":
            cost = m.get("total_cost_usd", 0)
            turns = m.get("num_turns", 0)
            u = m.get("usage", {})
            inp = u.get("input_tokens", 0)
            outp = u.get("output_tokens", 0)
            duration = m.get("duration_ms", 0)
        if t == "assistant":
            for c in m.get("message", {}).get("content", []):
                ct = c.get("type", "")
                if ct == "text":
                    blocks.append(("assistant", c.get("text", "")))
                elif ct == "tool_use":
                    name = c.get("name", "")
                    inp_str = json.dumps(c.get("input", {}))
                    blocks.append(("tool_use", f"{name}: {inp_str[:300]}"))
        if t == "user":
            r = m.get("tool_use_result", "")
            if isinstance(r, str) and r:
                blocks.append(("tool_result", r[:1000]))
            elif isinstance(r, list):
                for item in r:
                    if isinstance(item, dict) and item.get("type") == "text":
                        blocks.append(("tool_result", item.get("text", "")[:1000]))
    return blocks, {"cost": cost, "turns": turns, "input": inp, "output": outp,
                    "duration": duration, "model": model, "session": session}

def render_blocks(blocks):
    out = []
    for kind, text in blocks:
        escaped = html.escape(text)
        if kind == "assistant":
            out.append(f'<div class="msg a"><div class="label">Assistant</div><pre>{escaped}</pre></div>')
        elif kind == "tool_use":
            out.append(f'<div class="msg t"><div class="label">Tool Call</div><code>{escaped}</code></div>')
        elif kind == "tool_result":
            cls = "e" if text.startswith("Error:") else "r"
            label = "Error" if cls == "e" else "Result"
            out.append(f'<div class="msg {cls}"><div class="label">{label}</div><pre>{escaped}</pre></div>')
    return "\n".join(out)

if not os.path.exists(state_file):
    print("No state file, skipping transcript")
    sys.exit(0)

prs = [l.strip().split()[0] for l in open(state_file) if l.strip()]
sections = []
total_cost = 0

for pr_number in prs:
    stream_file = f"/tmp/claude-pr-{pr_number}-output.json"
    if not os.path.exists(stream_file):
        continue
    blocks, stats = parse_stream_json(stream_file)
    if not blocks:
        continue
    total_cost += stats["cost"]
    dur_s = stats["duration"] // 1000
    dur_str = f"{dur_s // 60}m {dur_s % 60}s" if dur_s >= 60 else f"{dur_s}s"
    sections.append(f'''
<div class="issue"><h2>PR #{pr_number}</h2>
<details open>
<summary>Address Review — {stats["turns"]} turns, ${stats["cost"]:.4f}, {dur_str}</summary>
<div class="phase">{render_blocks(blocks)}</div>
</details>
</div>''')

with open(output_file, "w") as f:
    f.write(f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Review Agent Transcript</title>
<style>
body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 1100px; margin: 0 auto; padding: 2em; background: #f5f5f5; color: #333; }}
h1 {{ border-bottom: 2px solid #333; padding-bottom: 0.3em; }}
h2 {{ margin-top: 2em; }}
details {{ margin: 0.5em 0; }}
details summary {{ cursor: pointer; font-weight: 600; color: #555; padding: 0.5em 0; font-size: 1.05em; }}
details[open] summary {{ margin-bottom: 0.5em; }}
.phase {{ border-left: 2px solid #ddd; padding-left: 1em; margin-left: 0.5em; }}
.msg {{ margin: 0.4em 0; padding: 0.6em; border-radius: 6px; }}
.msg .label {{ font-size: 0.7em; font-weight: 600; color: #666; text-transform: uppercase; margin-bottom: 0.2em; }}
.msg pre, .msg code {{ margin: 0; white-space: pre-wrap; word-wrap: break-word; font-size: 0.82em; }}
.msg pre {{ max-height: 250px; overflow-y: auto; }}
.a {{ background: #e8f4fd; border-left: 3px solid #0366d6; }}
.t {{ background: #f6f8fa; border-left: 3px solid #6f42c1; }}
.r {{ background: #f6f8fa; border-left: 3px solid #28a745; }}
.e {{ background: #fff5f5; border-left: 3px solid #cb2431; }}
</style>
</head>
<body>
<p><a href="../../review-agent-report/artifacts/review-agent-report.html">Back to summary report</a></p>
<h1>Review Agent Transcript</h1>
<p style="color:#666">Total cost: ${total_cost:.4f}</p>
{"".join(sections) if sections else "<p>No transcript data available.</p>"}
</body>
</html>''')
print(f"Transcript written: {len(sections)} PR(s)")
TRANSCRIPT_PY

echo ""
echo "=== Processing Summary ==="
echo "PR: #$PR_NUMBER"
echo "Result: $([ $EXIT_CODE -eq 0 ] && echo 'SUCCESS' || echo 'FAILED')"
echo "=========================="
