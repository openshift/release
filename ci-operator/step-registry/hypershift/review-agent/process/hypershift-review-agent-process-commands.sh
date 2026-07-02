#!/bin/bash
set -euo pipefail

echo "=== HyperShift Review Agent Process ==="

# This step addresses review comments on a single PR.
# It uses the /openshift-developer:address-review-pr skill which handles:
# - Fetching and filtering PR comments (deduplication, bot filtering, authorization)
# - Categorizing comments by priority (blocking, change requests, questions, suggestions)
# - Making code changes, posting replies, and pushing

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

# Clone HyperShift fork (we work on branches here)
echo "Cloning HyperShift repository..."
git clone https://github.com/hypershift-community/hypershift /tmp/hypershift

# Install tool dependencies
echo "Installing tool dependencies..."
GOFLAGS="" go install golang.org/x/tools/gopls@v0.21.0
python3.9 -m ensurepip --user 2>/dev/null || true
python3.9 -m pip install --user pre-commit 2>&1 | tail -1
export PATH="${GOPATH:-$HOME/go}/bin:$HOME/.local/bin:$PATH"

# Force HTTPS for all github.com git operations (plugin install defaults to SSH which lacks host keys in CI)
git config --global url."https://github.com/".insteadOf "git@github.com:"

# Install the openshift-developer plugin (bundles jira, ci, golang, prodsec-skills, git)
echo "Installing Claude Code plugins..."
claude plugin marketplace add openshift-eng/ai-helpers
claude plugin marketplace add RedHatProductSecurity/prodsec-skills
claude plugin install openshift-developer@ai-helpers
claude plugin install prow-agent@ai-helpers

cd /tmp/hypershift

# Configure git
git config user.name "OpenShift CI Bot"
git config user.email "ci-bot@redhat.com"

# Add upstream remote for PR operations
git remote add upstream https://github.com/openshift/hypershift.git

# Generate GitHub App installation token
echo "Generating GitHub App token..."

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"
APP_ID_FILE="${GITHUB_APP_CREDS_DIR}/app-id"
INSTALLATION_ID_FILE="${GITHUB_APP_CREDS_DIR}/installation-id"
PRIVATE_KEY_FILE="${GITHUB_APP_CREDS_DIR}/private-key"
INSTALLATION_ID_UPSTREAM_FILE="${GITHUB_APP_CREDS_DIR}/o-h-installation-id"

if [ ! -f "$APP_ID_FILE" ] || [ ! -f "$INSTALLATION_ID_FILE" ] || [ ! -f "$PRIVATE_KEY_FILE" ] || [ ! -f "$INSTALLATION_ID_UPSTREAM_FILE" ]; then
  echo "GitHub App credentials not yet available in ${GITHUB_APP_CREDS_DIR}"
  echo "Available files:"
  ls -la "${GITHUB_APP_CREDS_DIR}/" || echo "Directory does not exist"
  echo ""
  echo "Waiting for Vault secretsync to complete. The following keys are required:"
  echo "  - app-id"
  echo "  - installation-id (for hypershift-community fork)"
  echo "  - o-h-installation-id (for openshift/hypershift upstream)"
  echo "  - private-key"
  echo ""
  echo "Exiting gracefully. Re-run once secrets are synced."
  exit 0
fi

APP_ID=$(cat "$APP_ID_FILE")
INSTALLATION_ID_FORK=$(cat "$INSTALLATION_ID_FILE")
INSTALLATION_ID_UPSTREAM=$(cat "$INSTALLATION_ID_UPSTREAM_FILE")

generate_github_token() {
  local INSTALL_ID=$1
  local NOW
  NOW=$(date +%s)
  local IAT=$((NOW - 60))
  local EXP=$((NOW + 600))

  local HEADER
  HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local PAYLOAD
  PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local SIGNATURE
  SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

  curl -s -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
    | jq -r '.token'
}

# Generate token for fork (hypershift-community/hypershift) - for pushing branches
echo "Generating GitHub App token for fork..."
GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token for fork"
  exit 1
fi
echo "Fork token generated successfully"

# Generate token for upstream (openshift/hypershift) - for reading PRs and comments
echo "Generating GitHub App token for upstream..."
GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token for upstream"
  exit 1
fi
echo "Upstream token generated successfully"

# Configure git to use the fork token for push operations via credential helper
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"

# Export upstream token as GITHUB_TOKEN for gh CLI (used for PR operations)
export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
echo "GitHub App tokens configured successfully"

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

# Wrapper: run claude via agentic-ci for native OTEL collection
run_claude() {
  local phase=$1; shift
  local pr_number=$1; shift
  local prompt="$1"; shift

  local phase_otel="/tmp/claude-${pr_number}-${phase}-otel.jsonl"

  agentic-ci run \
    --backend local \
    --harness claude-code \
    --model "${CLAUDE_MODEL}" \
    --workdir /tmp/hypershift \
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
    '{
      table_name: "address_review_agent",
      schema: {
        session_id: "string",
        agent: "string",
        pr_number: "string",
        result: "string",
        analyzed_at: "string",
        job_name: "string",
        build_id: "string"
      },
      schema_mapping: null,
      rows: [{
        session_id: $session_id,
        agent: "address-review",
        pr_number: $pr_number,
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
  --repo openshift/hypershift \
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

set +e
run_claude "address-review" "$PR_NUMBER" "/openshift-developer:address-review-pr $PR_NUMBER" \
  --append-system-prompt "You are addressing review comments on PR #$PR_NUMBER in openshift/hypershift. The PR was created from the hypershift-community fork." \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch Agent Skill Task" \
  --disallowedTools "${DISALLOWED_TOOLS[@]}" \
  --max-turns 200 \
  --effort max \
  2> "/tmp/claude-pr-${PR_NUMBER}-output.log" \
  | tee "/tmp/claude-pr-${PR_NUMBER}-output.json"
EXIT_CODE=$?
set -e

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
<p><a href="../../hypershift-review-agent-report/artifacts/review-agent-report.html">Back to summary report</a></p>
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
