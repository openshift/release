#!/bin/bash
set -euo pipefail

echo "=== Jira Agent Process ==="

# ── Configuration ──────────────────────────────────────────────────────────────

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY:-}" ]]; then
  echo "Applying Gangway override: JIRA_AGENT_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY}"
  export JIRA_AGENT_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY}"
fi

export JIRA_AGENT_AUTH_MODE="${JIRA_AGENT_AUTH_MODE:-app}"
export JIRA_AGENT_FORK_ORG="${JIRA_AGENT_FORK_ORG:-}"
export JIRA_AGENT_PAT_KEY="${JIRA_AGENT_PAT_KEY:-gh-pat}"
export JIRA_AGENT_COMPONENT_REPO_MAP="${JIRA_AGENT_COMPONENT_REPO_MAP:-}"

# When a component-repo map is set, UPSTREAM_REPO is resolved per-issue from the Jira component.
# Otherwise it must be set statically.
DYNAMIC_REPO=false
if [ -n "$JIRA_AGENT_COMPONENT_REPO_MAP" ]; then
  DYNAMIC_REPO=true
  echo "Dynamic repo mode: upstream repo will be resolved per-issue from Jira component"
  # Set a placeholder so downstream exports don't fail; resolved before each issue
  : "${JIRA_AGENT_UPSTREAM_REPO:=pending-resolution}"
elif [ -z "${JIRA_AGENT_UPSTREAM_REPO:-}" ]; then
  echo "ERROR: Required env var JIRA_AGENT_UPSTREAM_REPO is not set"
  exit 1
fi

# JIRA_AGENT_FORK_REPO is required in App mode, optional in PAT mode (derived from FORK_ORG)
if [ "$JIRA_AGENT_AUTH_MODE" = "app" ]; then
  if [ "$DYNAMIC_REPO" = false ] && [ -z "${JIRA_AGENT_FORK_REPO:-}" ]; then
    echo "ERROR: Required env var JIRA_AGENT_FORK_REPO is not set (required in App auth mode)"
    exit 1
  fi
elif [ "$JIRA_AGENT_AUTH_MODE" = "pat" ]; then
  if [ -z "$JIRA_AGENT_FORK_ORG" ]; then
    echo "ERROR: JIRA_AGENT_FORK_ORG is required in PAT auth mode"
    exit 1
  fi
  # Derive FORK_REPO from FORK_ORG + upstream repo name if not explicitly set
  if [ "$DYNAMIC_REPO" = false ] && [ -z "${JIRA_AGENT_FORK_REPO:-}" ]; then
    JIRA_AGENT_FORK_REPO="${JIRA_AGENT_FORK_ORG}/${JIRA_AGENT_UPSTREAM_REPO#*/}"
  fi
else
  echo "ERROR: Unknown JIRA_AGENT_AUTH_MODE: ${JIRA_AGENT_AUTH_MODE} (expected 'app' or 'pat')"
  exit 1
fi

if [ -z "${JIRA_AGENT_ISSUE_KEY:-}" ] && [ -z "${JIRA_AGENT_JQL:-}" ]; then
  echo "ERROR: JIRA_AGENT_JQL must be set when JIRA_AGENT_ISSUE_KEY is not provided"
  exit 1
fi

export FORK_ORG="${JIRA_AGENT_FORK_REPO%%/*}"
export UPSTREAM_INSTALL_ID_KEY="${JIRA_AGENT_UPSTREAM_INSTALLATION_ID_KEY:-o-h-installation-id}"
export FORK_INSTALL_ID_KEY="${JIRA_AGENT_FORK_INSTALLATION_ID_KEY:-installation-id}"
export REVIEW_LANGUAGE="${JIRA_AGENT_REVIEW_LANGUAGE:-go}"
export REVIEW_PROFILE="${JIRA_AGENT_REVIEW_PROFILE:-}"
export SLACK_EMOJI="${JIRA_AGENT_SLACK_EMOJI:-:robot:}"
export JIRA_BASE_URL="${JIRA_BASE_URL:-https://redhat.atlassian.net}"
export MAX_ISSUES=${JIRA_AGENT_MAX_ISSUES:-1}
export STATE_FILE="${SHARED_DIR}/processed-issues.txt"
export REPORT_STEP="${JIRA_AGENT_REPORT_STEP:-jira-agent-report}"
export SUBAGENT_PROMPT="SUBAGENTS: Launch ALL subagents in parallel (single message with multiple Task tool calls) for maximum speed. Each subagent should be given subagent_type: \"general-purpose\". Do NOT set the model parameter — let subagents inherit the parent model, as these analysis tasks require a capable model."
export SECURITY_PROMPT="SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v', 'git remote get-url origin', 'git config --list', 'git config --global credential.helper', or 'cat ~/.gitconfig'."

export BASH_DEFAULT_TIMEOUT_MS=1200000
export BASH_MAX_TIMEOUT_MS=1200000

echo "Configuration: AUTH_MODE=$JIRA_AGENT_AUTH_MODE MAX_ISSUES=$MAX_ISSUES"

# ── Source libraries ───────────────────────────────────────────────────────────

source "${SHARED_DIR}/github-app-auth.sh"
source "${SHARED_DIR}/slack-pr-notify.sh"
source "${SHARED_DIR}/claude-helpers.sh"
source "${SHARED_DIR}/jira-helpers.sh"
source "${SHARED_DIR}/git-helpers.sh"

# ── Setup ──────────────────────────────────────────────────────────────────────

git config --global url."https://github.com/".insteadOf "git@github.com:"
mkdir -p ~/.ssh
if ! ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>&1; then
  echo "Warning: ssh-keyscan failed — SSH host key verification may fail later"
fi

echo "Installing Claude Code plugins..."
claude plugin marketplace add openshift-eng/ai-helpers
claude plugin marketplace add RedHatProductSecurity/prodsec-skills
claude plugin install openshift-developer@ai-helpers
claude plugin install prow-agent@ai-helpers

# ── Credentials ───────────────────────────────────────────────────────────────

load_credentials
load_jira_credentials
load_slack_credentials
load_github_slack_map

if [ -n "${JIRA_AGENT_TOOL_SETUP_SCRIPT:-}" ]; then
  echo "Running project-specific tool setup..."
  eval "$JIRA_AGENT_TOOL_SETUP_SCRIPT"
fi
export PATH="${GOPATH:-$HOME/go}/bin:$HOME/.local/bin:$PATH"

# ── Clone, fork, sync ────────────────────────────────────────────────────────
# In static mode: clone once before the issue loop.
# In dynamic mode: deferred to per-issue (repo changes based on Jira component).

if [ "$DYNAMIC_REPO" = false ]; then
  ensure_fork_exists

  echo "Cloning ${JIRA_AGENT_FORK_REPO}..."
  git clone "https://github.com/${JIRA_AGENT_FORK_REPO}" /tmp/project-repo
  cd /tmp/project-repo

  validate_jira_plugin
  sync_fork_with_upstream
fi

# ── Query Jira ─────────────────────────────────────────────────────────────────

query_jira_issues

# ── Process each issue ─────────────────────────────────────────────────────────

PROCESSED_COUNT=0
FAILED_COUNT=0
TOTAL=0

while IFS= read -r line; do
  if [ $TOTAL -ge "$MAX_ISSUES" ]; then
    echo "Reached maximum issues limit ($MAX_ISSUES). Stopping."
    break
  fi

  issue_key=$(echo "$line" | awk '{print $1}')
  issue_summary=$(echo "$line" | cut -d' ' -f2-)

  # In dynamic mode, resolve the upstream repo from the issue's Jira component
  # and set up a fresh clone/fork/sync for each issue
  if [ "$DYNAMIC_REPO" = true ]; then
    resolve_upstream_repo "$issue_key"
    setup_repo
    validate_jira_plugin
  fi

  if process_single_issue "$issue_key" "$issue_summary"; then
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
  TOTAL=$((TOTAL + 1))

  # Rate-limit between issues to avoid GitHub API abuse detection
  if [ $TOTAL -lt "$MAX_ISSUES" ]; then
    echo "Waiting 60 seconds before next issue..."
    sleep 60
  fi
done <<< "$ISSUES"

# Generate conversation transcript HTML from stream-json files in /tmp
echo "Generating conversation transcript..."
python3 - "$STATE_FILE" "$ARTIFACT_DIR" "$REPORT_STEP" << 'TRANSCRIPT_PY'
import json, html, sys, os

state_file = sys.argv[1]
artifact_dir = sys.argv[2]
report_step = sys.argv[3] if len(sys.argv) > 3 else "jira-agent-report"
output_file = os.path.join(artifact_dir, "jira-agent-transcript.html")

PHASES = [
    ("output", "Phase 1: Solve"),
    ("review", "Phase 2: Review"),
    ("fix", "Phase 3: Fix"),
    ("pr", "Phase 4: PR Creation"),
]

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

issues = [l.strip().split()[0] for l in open(state_file) if l.strip()]

STYLE = """
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 1100px; margin: 0 auto; padding: 2em; background: #f5f5f5; color: #333; }
h1 { border-bottom: 2px solid #333; padding-bottom: 0.3em; }
h2 { margin-top: 2em; }
details { margin: 0.5em 0; }
details summary { cursor: pointer; font-weight: 600; color: #555; padding: 0.5em 0; font-size: 1.05em; }
details[open] summary { margin-bottom: 0.5em; }
.phase { border-left: 2px solid #ddd; padding-left: 1em; margin-left: 0.5em; }
.msg { margin: 0.4em 0; padding: 0.6em; border-radius: 6px; }
.msg .label { font-size: 0.7em; font-weight: 600; color: #666; text-transform: uppercase; margin-bottom: 0.2em; }
.msg pre, .msg code { margin: 0; white-space: pre-wrap; word-wrap: break-word; font-size: 0.82em; }
.msg pre { max-height: 250px; overflow-y: auto; }
.a { background: #e8f4fd; border-left: 3px solid #0366d6; }
.t { background: #f6f8fa; border-left: 3px solid #6f42c1; }
.r { background: #f6f8fa; border-left: 3px solid #28a745; }
.e { background: #fff5f5; border-left: 3px solid #cb2431; }
"""

back_link = f'<p><a href="../../{report_step}/artifacts/jira-agent-report.html">Back to summary report</a></p>'
written = 0

for issue_key in issues:
    issue_sections = []
    issue_cost = 0
    for phase_key, phase_label in PHASES:
        stream_file = f"/tmp/claude-{issue_key}-{phase_key}.json"
        if not os.path.exists(stream_file):
            continue
        blocks, stats = parse_stream_json(stream_file)
        if not blocks:
            continue
        issue_cost += stats["cost"]
        dur_s = stats["duration"] // 1000
        dur_str = f"{dur_s // 60}m {dur_s % 60}s" if dur_s >= 60 else f"{dur_s}s"
        is_open = "open" if phase_key == "output" else ""
        issue_sections.append(f'''
<details {is_open}>
<summary>{phase_label} — {stats["turns"]} turns, ${stats["cost"]:.4f}, {dur_str}</summary>
<div class="phase">{render_blocks(blocks)}</div>
</details>''')
    if not issue_sections:
        continue
    issue_file = os.path.join(artifact_dir, f"jira-agent-transcript-{issue_key}.html")
    with open(issue_file, "w") as f:
        f.write(f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Transcript: {issue_key}</title>
<style>{STYLE}</style>
</head>
<body>
{back_link}
<h1>Transcript: {issue_key}</h1>
<p style="color:#666">Cost: ${issue_cost:.4f}</p>
{"".join(issue_sections)}
</body>
</html>''')
    written += 1

print(f"Transcripts written: {written} issue(s)")
TRANSCRIPT_PY

echo ""
echo "=== Processing Summary ==="
echo "Processed: $PROCESSED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "=========================="
