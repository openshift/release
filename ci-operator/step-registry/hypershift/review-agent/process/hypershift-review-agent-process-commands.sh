#!/bin/bash
set -euo pipefail

echo "=== HyperShift Review Agent Process ==="

# State file for sharing results with report step
STATE_FILE="${SHARED_DIR}/processed-prs.txt"

# Clone ai-helpers repository (contains /utils:address-reviews command)
echo "Cloning ai-helpers repository..."
git clone https://github.com/openshift-eng/ai-helpers /tmp/ai-helpers

# Clone HyperShift fork (we work on branches here)
echo "Cloning HyperShift repository..."
git clone https://github.com/hypershift-community/hypershift /tmp/hypershift

# Copy address-reviews command to a stable location outside the git working tree
echo "Setting up Claude commands..."
cp /tmp/ai-helpers/plugins/utils/commands/address-reviews.md /tmp/address-reviews.md

# Create comment analyzer script (used to filter already-addressed comments)
# This script is embedded inline to comply with step-registry file naming requirements
cat > /tmp/comment_analyzer.py << 'COMMENT_ANALYZER_EOF'
#!/usr/bin/env python3
"""
Analyzes PR comments to determine which need bot attention.
Outputs JSON list of thread/comment IDs requiring response.

This script prevents duplicate bot responses by analyzing conversation
timelines and identifying only threads where:
1. No bot reply exists, OR
2. A human commented AFTER the last bot reply
"""

from __future__ import annotations

import json
import subprocess
import sys
from functools import lru_cache
from typing import Any

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

# Known bot accounts that should not trigger responses
BOT_ACCOUNTS = [
    "hypershift-jira-solve-ci[bot]",
    "hypershift-jira-solve-ci",
]

# Approved bots that ARE allowed to trigger responses
APPROVED_BOTS = [
    "coderabbitai",
    "coderabbitai[bot]",
]

# Cache for authorization results to minimize API calls
_auth_cache: dict[str, bool] = {}


def run_gh(args: list[str]) -> Any:
    """Run gh CLI command and return JSON output."""
    result = subprocess.run(
        ["gh"] + args,
        capture_output=True,
        text=True,
        check=True
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def is_bot(login: str) -> bool:
    """Check if login is a known bot account."""
    if not login:
        return False
    return login in BOT_ACCOUNTS or login.endswith("[bot]")


def is_openshift_org_member(login: str) -> bool:
    """Check if user is a member of the openshift GitHub org.

    Returns True if member, False if not or on error (fail-safe).
    """
    try:
        # gh api returns 204 No Content for members, 404 for non-members
        result = subprocess.run(
            ["gh", "api", f"orgs/openshift/members/{login}"],
            capture_output=True,
            text=True
        )
        # 204 No Content means user is a member (exit code 0, empty response)
        # 404 means not a member (exit code non-zero)
        return result.returncode == 0
    except Exception as e:
        print(f"Warning: Failed to check org membership for {login}: {e}", file=sys.stderr)
        return False


def _parse_simple_yaml_list(content: str, key: str) -> list[str]:
    """Simple YAML list parser for OWNERS files (fallback when PyYAML unavailable).

    Parses simple YAML like:
    approvers:
    - user1
    - user2
    """
    result = []
    in_key = False
    for line in content.split('\n'):
        stripped = line.strip()
        if stripped.startswith(f"{key}:"):
            in_key = True
            continue
        if in_key:
            if stripped.startswith("- "):
                result.append(stripped[2:].strip())
            elif stripped and not stripped.startswith("#") and ":" in stripped:
                # New key started
                in_key = False
    return result


def _parse_simple_yaml_aliases(content: str) -> dict[str, list[str]]:
    """Simple YAML aliases parser for OWNERS_ALIASES (fallback when PyYAML unavailable).

    Parses:
    aliases:
      alias-name:
      - user1
      - user2
    """
    aliases: dict[str, list[str]] = {}
    current_alias = None
    in_aliases = False

    for line in content.split('\n'):
        stripped = line.rstrip()
        if stripped.startswith("aliases:"):
            in_aliases = True
            continue
        if not in_aliases:
            continue

        # Check indentation to determine structure
        if stripped and not stripped.startswith(" ") and not stripped.startswith("\t"):
            # No longer in aliases section
            break

        stripped = stripped.strip()
        if not stripped or stripped.startswith("#"):
            continue

        if stripped.endswith(":") and not stripped.startswith("- "):
            # New alias name
            current_alias = stripped[:-1].strip()
            aliases[current_alias] = []
        elif stripped.startswith("- ") and current_alias:
            aliases[current_alias].append(stripped[2:].strip())

    return aliases


@lru_cache(maxsize=1)
def get_all_authorized_users() -> set[str]:
    """Build a set of all authorized users.

    Collects into one set:
    1. Approved bots
    2. All usernames from all aliases in OWNERS_ALIASES
    3. Any direct usernames in OWNERS (both simple and filters-based formats)

    Uses lru_cache to only fetch once per run.
    """
    authorized: set[str] = set()
    aliases: dict[str, list[str]] = {}

    # 1. Add approved bots
    authorized.update(APPROVED_BOTS)

    # 2. Fetch OWNERS_ALIASES - collect ALL users from ALL aliases
    try:
        result = subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github.raw",
             "repos/openshift/hypershift/contents/OWNERS_ALIASES"],
            capture_output=True,
            text=True,
            check=True
        )
        if HAS_YAML:
            aliases_data = yaml.safe_load(result.stdout)
            if aliases_data and "aliases" in aliases_data:
                aliases = aliases_data["aliases"]
        else:
            aliases = _parse_simple_yaml_aliases(result.stdout)

        # Add all users from all aliases
        for alias_name, members in aliases.items():
            authorized.update(members)
    except Exception as e:
        print(f"Warning: Failed to fetch OWNERS_ALIASES: {e}", file=sys.stderr)

    # 3. Fetch OWNERS - collect any direct usernames (not alias references)
    try:
        result = subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github.raw",
             "repos/openshift/hypershift/contents/OWNERS"],
            capture_output=True,
            text=True,
            check=True
        )
        if HAS_YAML:
            owners_data = yaml.safe_load(result.stdout)
            if owners_data:
                # Helper to add entries (skip if it's an alias reference)
                def add_entries(entries: list):
                    for entry in entries:
                        if entry not in aliases:  # Direct username, not an alias
                            authorized.add(entry)

                # Simple format: top-level approvers/reviewers
                add_entries(owners_data.get("approvers", []))
                add_entries(owners_data.get("reviewers", []))

                # Filters-based format: nested under filters
                if "filters" in owners_data:
                    for pattern, config in owners_data["filters"].items():
                        if isinstance(config, dict):
                            add_entries(config.get("approvers", []))
                            add_entries(config.get("reviewers", []))
        else:
            # Fallback parsing (simple format only - filters format requires YAML)
            for entry in _parse_simple_yaml_list(result.stdout, "approvers"):
                if entry not in aliases:
                    authorized.add(entry)
            for entry in _parse_simple_yaml_list(result.stdout, "reviewers"):
                if entry not in aliases:
                    authorized.add(entry)
    except Exception as e:
        print(f"Warning: Failed to fetch OWNERS: {e}", file=sys.stderr)

    return authorized


def is_authorized_author(login: str) -> bool:
    """Check if author is authorized to trigger review agent responses.

    Authorized authors are:
    1. Users in the combined set (approved bots + OWNERS + OWNERS_ALIASES)
    2. Members of the openshift GitHub organization (fallback)
    """
    if not login:
        return False

    # Check cache first
    if login in _auth_cache:
        return _auth_cache[login]

    # 1. Check combined set (bots + OWNERS + OWNERS_ALIASES)
    authorized_users = get_all_authorized_users()
    if login.lower() in {u.lower() for u in authorized_users}:
        _auth_cache[login] = True
        print(f"  Author '{login}' authorized: in approved bots/OWNERS/OWNERS_ALIASES", file=sys.stderr)
        return True

    # 2. Fallback: check openshift org membership
    if is_openshift_org_member(login):
        _auth_cache[login] = True
        print(f"  Author '{login}' authorized: openshift org member", file=sys.stderr)
        return True

    # Not authorized
    _auth_cache[login] = False
    print(f"  Author '{login}' NOT authorized: not in org, OWNERS, or approved bots", file=sys.stderr)
    return False


def analyze_review_threads(pr_number: int) -> list[dict]:
    """Analyze review threads and return those needing attention."""
    query = '''
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              isOutdated
              comments(first: 100) {
                nodes {
                  id
                  author { login }
                  createdAt
                  body
                }
              }
            }
          }
        }
      }
    }
    '''

    result = run_gh([
        "api", "graphql",
        "-f", f"query={query}",
        "-f", "owner=openshift",
        "-f", "repo=hypershift",
        "-F", f"number={pr_number}"
    ])

    threads = result["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    needs_attention = []

    for thread in threads:
        # Skip resolved or outdated threads
        if thread["isResolved"] or thread["isOutdated"]:
            continue

        comments = sorted(
            thread["comments"]["nodes"],
            key=lambda c: c["createdAt"]
        )

        if not comments:
            continue

        # Find last human and last bot comment
        last_human = None
        last_bot = None

        for comment in comments:
            author = comment["author"]["login"] if comment["author"] else "unknown"
            if is_bot(author):
                last_bot = comment
            else:
                last_human = comment

        # Needs attention if no bot reply, or human commented after bot
        if last_bot is None:
            last_author = last_human["author"]["login"] if last_human and last_human["author"] else "unknown"
            # Check if author is authorized
            if not is_authorized_author(last_author):
                continue
            needs_attention.append({
                "type": "review_thread",
                "id": thread["id"],
                "last_human_comment": last_human["body"][:200] if last_human else None,
                "last_human_author": last_author,
                "reason": "no_bot_reply"
            })
        elif last_human and last_human["createdAt"] > last_bot["createdAt"]:
            last_author = last_human["author"]["login"] if last_human["author"] else "unknown"
            # Check if author is authorized
            if not is_authorized_author(last_author):
                continue
            needs_attention.append({
                "type": "review_thread",
                "id": thread["id"],
                "last_human_comment": last_human["body"][:200],
                "last_human_author": last_author,
                "reason": "human_followup_after_bot"
            })

    return needs_attention


def analyze_review_bodies(pr_number: int) -> list[dict]:
    """Analyze review bodies (main text of reviews) and return those needing attention.

    Review bodies are separate from review threads (line-level comments) and issue comments.
    A review body is the main text submitted when a reviewer submits their review.
    """
    query = '''
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviews(first: 100) {
            nodes {
              id
              author { login }
              body
              state
              submittedAt
            }
          }
        }
      }
    }
    '''

    result = run_gh([
        "api", "graphql",
        "-f", f"query={query}",
        "-f", "owner=openshift",
        "-f", "repo=hypershift",
        "-F", f"number={pr_number}"
    ])

    reviews = result["data"]["repository"]["pullRequest"]["reviews"]["nodes"]
    needs_attention = []

    # Get issue comments to check if bot has replied to any review
    try:
        issue_comments = run_gh([
            "api", f"repos/openshift/hypershift/issues/{pr_number}/comments"
        ])
    except subprocess.CalledProcessError:
        issue_comments = []

    # Find last bot comment time from issue comments
    bot_comment_times = []
    if issue_comments:
        for c in issue_comments:
            if c["user"]["login"] in BOT_ACCOUNTS:
                bot_comment_times.append(c["created_at"])
    last_bot_time = max(bot_comment_times) if bot_comment_times else None

    for review in reviews:
        # Skip reviews without bodies or from bots
        author = review["author"]["login"] if review["author"] else None
        if not author or is_bot(author):
            continue

        body = review.get("body", "").strip()
        if not body:
            continue

        # Check if author is authorized
        if not is_authorized_author(author):
            continue

        submitted_at = review["submittedAt"]

        # Needs attention if no bot reply, or review was submitted after last bot comment
        if last_bot_time is None or submitted_at > last_bot_time:
            needs_attention.append({
                "type": "review_body",
                "id": review["id"],
                "author": author,
                "state": review["state"],
                "body": body[:500],  # Include more context for review bodies
                "submitted_at": submitted_at,
                "reason": "no_bot_reply" if last_bot_time is None else "review_after_bot_reply"
            })

    return needs_attention


def analyze_issue_comments(pr_number: int) -> list[dict]:
    """Analyze issue comments (general PR comments) and return those needing attention."""
    try:
        comments = run_gh([
            "api", f"repos/openshift/hypershift/issues/{pr_number}/comments"
        ])
    except subprocess.CalledProcessError:
        return []

    if not comments:
        return []

    # Separate human and bot comments
    human_comments = [c for c in comments if not is_bot(c["user"]["login"])]
    bot_comments = [c for c in comments if c["user"]["login"] in BOT_ACCOUNTS]

    if not human_comments:
        return []

    # Find the last bot comment timestamp
    last_bot_time = None
    if bot_comments:
        last_bot_time = max(c["created_at"] for c in bot_comments)

    needs_attention = []

    # Find human comments after last bot reply
    for comment in human_comments:
        if last_bot_time is None or comment["created_at"] > last_bot_time:
            author = comment["user"]["login"]
            # Check if author is authorized
            if not is_authorized_author(author):
                continue
            needs_attention.append({
                "type": "issue_comment",
                "id": comment["id"],
                "author": author,
                "body": comment["body"][:200],
                "created_at": comment["created_at"],
                "reason": "no_bot_reply" if last_bot_time is None else "human_followup_after_bot"
            })

    return needs_attention


def main():
    if len(sys.argv) < 2:
        print("Usage: comment_analyzer.py <pr_number>", file=sys.stderr)
        sys.exit(1)

    pr_number = int(sys.argv[1])

    try:
        review_threads = analyze_review_threads(pr_number)
        review_bodies = analyze_review_bodies(pr_number)
        issue_comments = analyze_issue_comments(pr_number)
    except subprocess.CalledProcessError as e:
        print(json.dumps({
            "error": f"Failed to query GitHub: {e.stderr}",
            "pr_number": pr_number
        }))
        sys.exit(1)
    except (KeyError, TypeError) as e:
        print(json.dumps({
            "error": f"Failed to parse GitHub response: {str(e)}",
            "pr_number": pr_number
        }))
        sys.exit(1)

    result = {
        "pr_number": pr_number,
        "needs_attention": review_threads + review_bodies + issue_comments,
        "summary": {
            "review_threads": len(review_threads),
            "review_bodies": len(review_bodies),
            "issue_comments": len(issue_comments),
            "total": len(review_threads) + len(review_bodies) + len(issue_comments)
        }
    }

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
COMMENT_ANALYZER_EOF
chmod +x /tmp/comment_analyzer.py

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

# Check if all required credentials exist
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

# Function to generate GitHub App token for a given installation ID
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

# Configuration: maximum PRs to process per run (default: 10)
MAX_PRS=${REVIEW_AGENT_MAX_PRS:-10}
echo "Configuration: MAX_PRS=$MAX_PRS"

# Check for target PR mode
# - REVIEW_AGENT_TARGET_PR: Explicit PR number override
# - PULL_NUMBER: Used for single-PR presubmit job (not in batch-only mode)
# - REVIEW_AGENT_BATCH_ONLY: Forces batch mode, ignores PULL_NUMBER (for periodic/rehearsal)
if [ "${REVIEW_AGENT_BATCH_ONLY:-}" = "true" ]; then
  TARGET_PR="${REVIEW_AGENT_TARGET_PR:-}"
else
  TARGET_PR="${REVIEW_AGENT_TARGET_PR:-${PULL_NUMBER:-}}"
fi

if [ -n "$TARGET_PR" ]; then
  echo "Target PR mode: Processing only PR #$TARGET_PR"

  # Fetch the specific PR details
  PR_INFO=$(gh pr view "$TARGET_PR" \
    --repo openshift/hypershift \
    --json number,title,headRefName \
    --jq '"\(.number) \(.headRefName) \(.title)"' 2>/dev/null || echo "")

  if [ -z "$PR_INFO" ]; then
    echo "ERROR: PR #$TARGET_PR not found or not accessible"
    exit 1
  fi

  PRS="$PR_INFO"
  MAX_PRS=1
else
  # Normal flow: Query GitHub for PRs created by jira-agent that need review attention
  # Criteria:
  # 1. Open PRs authored by the GitHub App (hypershift-jira-solve-ci)
  # 2. Have pending review comments
  echo "Batch mode: Querying GitHub for agent-created PRs with pending reviews..."

  # Get open PRs created by the jira-solve GitHub App
  PRS=$(gh pr list \
    --repo openshift/hypershift \
    --state open \
    --author app/hypershift-jira-solve-ci \
    --json number,title,headRefName \
    --limit "$MAX_PRS" \
    --jq '.[] | "\(.number) \(.headRefName) \(.title)"')
fi

if [ -z "$PRS" ]; then
  echo "No agent-created PRs found matching criteria"
  exit 0
fi

echo "Found PRs to check:"
echo "$PRS" | awk '{print "  - PR #" $1 ": " $3}'

# Counters for summary
PROCESSED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
TOTAL_PROCESSED=0

# Process each PR
while IFS= read -r line; do
  # Stop if we've reached the max PRs limit
  if [ $TOTAL_PROCESSED -ge $MAX_PRS ]; then
    echo "Reached maximum PRs limit ($MAX_PRS). Stopping."
    break
  fi

  PR_NUMBER=$(echo "$line" | awk '{print $1}')
  BRANCH_NAME=$(echo "$line" | awk '{print $2}')
  PR_TITLE=$(echo "$line" | cut -d' ' -f3-)

  echo ""
  echo "=========================================="
  echo "Checking: PR #$PR_NUMBER"
  echo "Branch: $BRANCH_NAME"
  echo "Title: $PR_TITLE"
  echo "=========================================="

  # Capture timestamp early for consistent logging
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Run comment analyzer to identify which comments actually need attention
  # This filters out threads where the bot has already replied and no human follow-up exists
  echo "Running comment analyzer for PR #$PR_NUMBER..."
  set +e
  # Capture stderr separately to preserve JSON output integrity
  ANALYSIS_STDERR_FILE="/tmp/pr-${PR_NUMBER}-analysis-stderr.txt"
  ANALYSIS_OUTPUT=$(python3 /tmp/comment_analyzer.py "$PR_NUMBER" 2>"$ANALYSIS_STDERR_FILE")
  ANALYSIS_EXIT=$?
  set -e

  # Log stderr (authorization decisions) for debugging
  if [ -s "$ANALYSIS_STDERR_FILE" ]; then
    echo "Authorization log for PR #$PR_NUMBER:"
    cat "$ANALYSIS_STDERR_FILE"
  fi

  if [ $ANALYSIS_EXIT -ne 0 ]; then
    echo "Comment analyzer failed for PR #$PR_NUMBER: $ANALYSIS_OUTPUT"
    echo "Stderr: $(cat "$ANALYSIS_STDERR_FILE" 2>/dev/null || echo 'none')"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
    echo "$PR_NUMBER $TIMESTAMP FAILED analyzer_error" >> "$STATE_FILE"
    continue
  fi

  # Extract summary counts from analysis
  NEEDS_ATTENTION_COUNT=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.total // 0')
  REVIEW_THREADS=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.review_threads // 0')
  REVIEW_BODIES=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.review_bodies // 0')
  ISSUE_COMMENTS=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.issue_comments // 0')

  if [ "$NEEDS_ATTENTION_COUNT" = "0" ] || [ -z "$NEEDS_ATTENTION_COUNT" ]; then
    echo "No comments need attention for PR #$PR_NUMBER (bot already replied to all threads), skipping"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
    continue
  fi

  echo "Found $REVIEW_THREADS review threads, $REVIEW_BODIES review bodies, and $ISSUE_COMMENTS issue comments needing attention for PR #$PR_NUMBER"

  # Save analysis for Claude context
  echo "$ANALYSIS_OUTPUT" > "/tmp/pr-${PR_NUMBER}-analysis.json"

  # Reset working directory and checkout the PR branch
  echo "Checking out branch: $BRANCH_NAME"
  git reset --hard HEAD
  git clean -fd
  git fetch origin "$BRANCH_NAME"
  git checkout -B "$BRANCH_NAME" "origin/$BRANCH_NAME"

  # Run address-reviews command non-interactively
  echo "Running: /utils:address-reviews $PR_NUMBER"

  # Load the skill content as system prompt
  SKILL_CONTENT=$(cat /tmp/address-reviews.md)

  # Load the analysis results for context
  NEEDS_ATTENTION_JSON=$(cat "/tmp/pr-${PR_NUMBER}-analysis.json")

  # Context for the review agent with filtered comments
  REVIEW_CONTEXT="IMPORTANT: You are addressing review comments on PR #$PR_NUMBER in the openshift/hypershift repository. The PR was created from the hypershift-community fork. After making changes, push to the fork branch. Use 'git push origin $BRANCH_NAME' to push changes. The gh CLI is authenticated to openshift/hypershift for reading PR information. SECURITY: Do NOT run commands that reveal git credentials.

CRITICAL - DUPLICATE PREVENTION: The following JSON contains ONLY the comments that need your attention. These are comments where either (1) you have not replied yet, or (2) a human has replied after your last response. ONLY address these specific comments. Ignore all other threads - they have already been addressed.

COMMENTS NEEDING ATTENTION:
$NEEDS_ATTENTION_JSON

RESPONSE RULES:
1. For each piece of feedback, choose ONE response mechanism only - never respond to the same feedback via both inline reply AND general PR comment
2. Only make code changes when explicitly requested (look for imperative language like 'change', 'fix', 'update', 'remove')
3. For questions or clarifications, reply with an explanation only - do not change code unless asked"

  set +e  # Don't exit on error for individual PRs
  echo "Starting Claude processing with streaming output..."
  # Redirect stdin from /dev/null to prevent Claude from consuming the while loop's here-string input
  RESULT=$(claude -p "$PR_NUMBER. $REVIEW_CONTEXT" \
    --system-prompt "$SKILL_CONTENT" \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch" \
    --max-turns 100 \
    --model "$CLAUDE_MODEL" \
    --verbose \
    --output-format stream-json \
    < /dev/null \
    2>&1 | tee "/tmp/claude-pr-${PR_NUMBER}-output.json")
  EXIT_CODE=$?
  set -e
  echo "Claude processing complete. Full output saved to /tmp/claude-pr-${PR_NUMBER}-output.json"

  if [ $EXIT_CODE -eq 0 ]; then
    echo "Successfully processed PR #$PR_NUMBER"
    echo ""
    echo "--- Claude output for PR #$PR_NUMBER ---"
    echo "$RESULT" | tail -50
    echo "--- End Claude output ---"
    echo ""
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    echo "$PR_NUMBER $TIMESTAMP SUCCESS" >> "$STATE_FILE"
  else
    echo "Failed to process PR #$PR_NUMBER"
    echo "Error output (last 20 lines):"
    echo "$RESULT" | tail -20
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "$PR_NUMBER $TIMESTAMP FAILED" >> "$STATE_FILE"
  fi

  # Increment total counter
  TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))

  # Rate limiting between PRs (60 seconds)
  if [ $TOTAL_PROCESSED -lt $MAX_PRS ]; then
    echo "Waiting 60 seconds before next PR..."
    sleep 60
  fi

done <<< "$PRS"

echo ""
echo "=== Processing Summary ==="
echo "Processed: $PROCESSED_COUNT"
echo "Skipped (no pending reviews): $SKIPPED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "=========================="
