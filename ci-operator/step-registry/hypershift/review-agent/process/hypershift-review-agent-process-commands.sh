#!/bin/bash
set -euo pipefail

echo "=== HyperShift Review Agent Process ==="

# State file for sharing results with report step
STATE_FILE="${SHARED_DIR}/processed-prs.txt"

# Clone ai-helpers repository (contains /utils:address-reviews command)
echo "Cloning ai-helpers repository..."
git clone https://github.com/openshift-eng/ai-helpers /tmp/ai-helpers
export CLAUDE_PLUGIN_ROOT=/tmp/ai-helpers/plugins/utils

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
import re
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

# Prow/CI bots whose comments should be ignored entirely
IGNORED_ACCOUNTS = [
    "openshift-ci-robot",
    "openshift-ci",
    "openshift-merge-robot",
    "openshift-bot",
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


def is_our_bot(login: str) -> bool:
    """Check if login is our bot account (whose comments count as replies)."""
    if not login:
        return False
    return login in BOT_ACCOUNTS


def is_approved_bot(login: str) -> bool:
    """Check if login is an approved bot whose comments should trigger responses."""
    if not login:
        return False
    return login in APPROVED_BOTS


def is_ignored_bot(login: str) -> bool:
    """Check if login is a bot that should be ignored (prow bots, unknown [bot] accounts)."""
    if not login:
        return False
    if login in BOT_ACCOUNTS or login in APPROVED_BOTS:
        return False
    return login in IGNORED_ACCOUNTS or login.endswith("[bot]")


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

        # Classify comments:
        #   our_bot: our bot's reply (counts as "addressed")
        #   actionable: human or approved bot comment (needs response)
        #   ignored: unrecognized bots (skip)
        last_actionable = None
        last_our_bot = None

        for comment in comments:
            author = comment["author"]["login"] if comment["author"] else "unknown"
            if is_our_bot(author):
                last_our_bot = comment
            elif is_ignored_bot(author):
                continue
            elif is_authorized_author(author):
                last_actionable = comment

        if last_actionable is None:
            continue

        last_author = last_actionable["author"]["login"] if last_actionable["author"] else "unknown"
        author_type = "approved_bot" if is_approved_bot(last_author) else "human"

        # Needs attention if no bot reply, or actionable comment after bot reply
        if last_our_bot is None:
            needs_attention.append({
                "type": "review_thread",
                "id": thread["id"],
                "last_comment": last_actionable["body"][:200],
                "last_author": last_author,
                "author_type": author_type,
                "reason": "no_bot_reply"
            })
        elif last_actionable["createdAt"] > last_our_bot["createdAt"]:
            needs_attention.append({
                "type": "review_thread",
                "id": thread["id"],
                "last_comment": last_actionable["body"][:200],
                "last_author": last_author,
                "author_type": author_type,
                "reason": "followup_after_bot"
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
              url
              author { login }
              body
              state
              submittedAt
              comments(first: 0) { totalCount }
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

    # Get bot issue comment bodies to check for review ID references
    try:
        issue_comments = run_gh([
            "api", f"repos/openshift/hypershift/issues/{pr_number}/comments",
            "--paginate"
        ])
    except subprocess.CalledProcessError:
        issue_comments = []

    bot_bodies = [
        c["body"] for c in (issue_comments or [])
        if c["user"]["login"] in BOT_ACCOUNTS
    ]

    for review in reviews:
        # Skip reviews without bodies, from our bot, or from ignored bots
        author = review["author"]["login"] if review["author"] else None
        if not author or is_our_bot(author) or is_ignored_bot(author):
            continue

        body = review.get("body", "").strip()
        if not body:
            continue

        # Check if author is authorized
        if not is_authorized_author(author):
            continue

        # Skip approved bot review bodies when inline comments exist.
        # Bot review bodies (e.g. CodeRabbit's "Actionable comments posted: N")
        # are machine-generated summaries of their inline comments. Those inline
        # comments are already handled by analyze_review_threads, so flagging the
        # body too causes Claude to address the same feedback twice.
        inline_count = review.get("comments", {}).get("totalCount", 0)
        if is_approved_bot(author) and inline_count > 0:
            continue

        review_id = review["id"]
        review_url = review.get("url", "")

        # Check if any bot comment references this specific review (by node ID or URL)
        replied = any(str(review_id) in b or (review_url and review_url in b) for b in bot_bodies)

        if not replied:
            needs_attention.append({
                "type": "review_body",
                "id": review_id,
                "url": review_url,
                "author": author,
                "author_type": "approved_bot" if is_approved_bot(author) else "human",
                "state": review["state"],
                "body": body[:500],
                "submitted_at": review["submittedAt"],
                "reason": "no_bot_reply"
            })

    return needs_attention


def analyze_issue_comments(pr_number: int) -> list[dict]:
    """Analyze issue comments (general PR comments) and return those needing attention.

    Since issue comments are flat (no threading), we rely on our bot
    including the comment URL when replying. A comment is considered
    addressed only if our bot's reply contains its URL or comment ID anchor.
    """
    try:
        comments = run_gh([
            "api", f"repos/openshift/hypershift/issues/{pr_number}/comments",
            "--paginate"
        ])
    except subprocess.CalledProcessError:
        return []

    if not comments:
        return []

    # Actionable comments: humans and approved bots (not our bot, not ignored bots)
    actionable_comments = [
        c for c in comments
        if not is_our_bot(c["user"]["login"]) and not is_ignored_bot(c["user"]["login"])
    ]
    # Our bot's comments (used for reply matching)
    bot_comments = [c for c in comments if is_our_bot(c["user"]["login"])]

    if not actionable_comments:
        return []

    # Collect all our bot comment bodies for reference matching
    bot_bodies = [c["body"] for c in bot_comments]

    needs_attention = []

    for comment in actionable_comments:
        author = comment["user"]["login"]
        # Check if author is authorized
        if not is_authorized_author(author):
            continue

        # Check if any bot comment references this specific comment
        comment_id = str(comment["id"])
        comment_url = comment.get("html_url", "")
        # Match by full URL or by the #issuecomment-{id} anchor with word boundary
        # to prevent #issuecomment-123 from matching #issuecomment-1234
        anchor_pattern = re.compile(rf"#issuecomment-{re.escape(comment_id)}(?!\d)")

        replied = any(
            anchor_pattern.search(body) or (comment_url and comment_url in body)
            for body in bot_bodies
        )

        if not replied:
            needs_attention.append({
                "type": "issue_comment",
                "id": comment["id"],
                "html_url": comment_url,
                "author": author,
                "author_type": "approved_bot" if is_approved_bot(author) else "human",
                "body": comment["body"][:200],
                "created_at": comment["created_at"],
                "reason": "no_bot_reply"
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

# Check if a PR needs rebase (branch behind base)
# Returns: 0 = needs rebase, 1 = no rebase needed, 2 = API error
check_rebase_needed() {
  local pr_number=$1
  local merge_state base_branch
  local pr_json
  if ! pr_json=$(gh pr view "$pr_number" --repo openshift/hypershift --json mergeStateStatus,baseRefName 2>/dev/null); then
    echo "main"
    return 2  # API error
  fi
  merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus // ""')
  base_branch=$(echo "$pr_json" | jq -r '.baseRefName // "main"')

  # GitHub evicts cached merge state for dormant PRs, returning UNKNOWN.
  # The first query triggers recomputation; retry after a brief wait.
  if [ "$merge_state" = "UNKNOWN" ]; then
    sleep 5
    if pr_json=$(gh pr view "$pr_number" --repo openshift/hypershift --json mergeStateStatus,baseRefName 2>/dev/null); then
      merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus // ""')
    fi
  fi

  echo "$base_branch"
  if [ "$merge_state" = "BEHIND" ] || [ "$merge_state" = "DIRTY" ]; then
    return 0  # needs rebase
  fi
  return 1  # no rebase needed
}

# Perform a rebase onto the upstream base branch
# On conflict, invokes Claude to resolve before continuing.
perform_rebase() {
  local base_branch=$1
  git fetch upstream "$base_branch"
  if git rebase "upstream/$base_branch"; then
    return 0
  fi

  echo "Rebase hit conflicts, invoking Claude to resolve..."
  local conflicted_files
  conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -z "$conflicted_files" ]; then
    echo "No conflicted files found, aborting rebase"
    git rebase --abort
    return 1
  fi

  echo "Conflicted files:"
  echo "$conflicted_files" | sed 's/^/  - /'

  # Set GIT_EDITOR so git rebase --continue doesn't try to open an interactive editor
  export GIT_EDITOR=true

  local resolve_prompt="You are resolving git rebase merge conflicts in the openshift/hypershift Go project.

CONFLICTED FILES:
$conflicted_files

INSTRUCTIONS:
1. For each conflicted file, read it and resolve the conflict markers (<<<<<<< / ======= / >>>>>>>).
2. Resolve conflicts by keeping both sides where appropriate, or choosing the correct version.
3. After resolving each file, run: git add <file>
4. After ALL conflicts are resolved, run: GIT_EDITOR=true git rebase --continue
5. Do NOT push — pushing is handled separately.
6. Do NOT abort the rebase.
7. If you truly cannot resolve a conflict, explain why."

  set +e
  claude -p "$resolve_prompt" \
    --allowedTools "Bash Read Write Edit Grep Glob" \
    --max-turns 30 \
    --effort max \
    --model "$CLAUDE_MODEL" \
    --verbose \
    --output-format stream-json \
    < /dev/null \
    2>&1 | tee "/tmp/claude-rebase-output.json"
  local resolve_exit=$?
  set -e

  # Save artifact for debugging
  if [ -f "/tmp/claude-rebase-output.json" ]; then
    cp "/tmp/claude-rebase-output.json" "${ARTIFACT_DIR}/claude-rebase-output.json" 2>/dev/null || true
  fi

  # Check if rebase completed (no longer in rebase state)
  if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
    echo "Claude could not fully resolve conflicts, aborting rebase"
    git rebase --abort
    return 1
  fi

  if [ $resolve_exit -ne 0 ]; then
    echo "Claude conflict resolution failed, aborting rebase"
    git rebase --abort 2>/dev/null || true
    return 1
  fi

  echo "Claude resolved conflicts successfully"
  return 0
}

# Get failed CI checks matching verify/unit/lint patterns
# Returns: 0 = success (outputs JSON), 2 = API error (outputs '[]')
get_failed_ci_checks() {
  local pr_number=$1
  local checks_json
  if ! checks_json=$(gh pr checks "$pr_number" --repo openshift/hypershift --json name,state 2>/dev/null); then
    echo '[]'
    return 2  # API error
  fi
  echo "$checks_json" | jq '[.[] | select(.state == "FAIL" or .state == "FAILURE" or .state == "fail" or .state == "failure") | select(.name | test("verify|unit|lint"; "i"))] // []'
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

# Refresh both GitHub App tokens and reconfigure credentials
refresh_github_tokens() {
  echo "Refreshing GitHub App tokens..."
  GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
  if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
    echo "WARNING: Failed to refresh fork token, continuing with existing token"
    return 1
  fi
  GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
  if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
    echo "WARNING: Failed to refresh upstream token, continuing with existing token"
    return 1
  fi
  git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"
  export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
  echo "GitHub App tokens refreshed successfully"
}

# Configuration: maximum PRs to process per run (default: 10)
MAX_PRS=${REVIEW_AGENT_MAX_PRS:-10}
echo "Configuration: MAX_PRS=$MAX_PRS"

# Shared prompt instruction for subagent behavior
SUBAGENT_PROMPT="SUBAGENTS: Launch ALL subagents in parallel (single message with multiple Task tool calls) for maximum speed. Each subagent should be given subagent_type: \"general-purpose\". Do NOT set the model parameter — let subagents inherit the parent model, as these analysis tasks require a capable model."

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
REBASED_COUNT=0
CI_FIX_COUNT=0
TOTAL_PROCESSED=0

# Helper: extract compact summary from stream-json output
extract_claude_summary() {
  local input_file=$1
  local output_file=$2
  python3 -c "
import json, sys
f = sys.argv[1]
result_line = system_line = None
tool_calls = []
tool_errors = []
for line in open(f):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    t = obj.get('type', '')
    if t == 'result':
        result_line = obj
    elif t == 'system':
        system_line = obj
    elif t == 'tool_use':
        tool_calls.append(obj.get('name', 'unknown'))
    if obj.get('is_error'):
        tool_errors.append(str(obj.get('content', ''))[:200])
summary = {}
if result_line:
    summary['result'] = (result_line.get('result') or '')[:5000]
    summary['usage'] = result_line.get('usage', {})
    summary['duration_ms'] = result_line.get('duration_ms', 0)
    summary['duration_api_ms'] = result_line.get('duration_api_ms', 0)
    summary['num_turns'] = result_line.get('num_turns', 0)
    summary['session_id'] = result_line.get('session_id', '')
    summary['total_cost_usd'] = result_line.get('total_cost_usd', 0)
    summary['modelUsage'] = result_line.get('modelUsage', {})
if system_line:
    summary['model'] = system_line.get('model', 'unknown')
    summary['tools'] = system_line.get('tools', [])
summary['tool_calls'] = tool_calls
summary['tool_errors'] = tool_errors
print(json.dumps(summary))
" "$input_file" > "$output_file" 2>/dev/null || true
}

# Process each PR
while IFS= read -r line; do
  # Stop if we've reached the max PRs limit
  if [ $TOTAL_PROCESSED -ge $MAX_PRS ]; then
    echo "Reached maximum PRs limit ($MAX_PRS). Stopping."
    break
  fi

  # Refresh tokens every 5 PRs to avoid expiry during long runs
  if [ $TOTAL_PROCESSED -gt 0 ] && [ $((TOTAL_PROCESSED % 5)) -eq 0 ]; then
    refresh_github_tokens
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

  # Initialize per-PR action tracking
  NEEDS_REVIEWS=false
  NEEDS_REBASE=false
  NEEDS_CI_FIX=false
  BASE_BRANCH="main"
  FAILED_CHECKS_JSON="[]"

  # ---- PHASE 1: DETECT (API-only, no checkout needed) ----

  # 1a. Check for pending review comments
  echo "Running comment analyzer for PR #$PR_NUMBER..."
  set +e
  ANALYSIS_STDERR_FILE="/tmp/pr-${PR_NUMBER}-analysis-stderr.txt"
  ANALYSIS_OUTPUT=$(python3 /tmp/comment_analyzer.py "$PR_NUMBER" 2>"$ANALYSIS_STDERR_FILE")
  ANALYSIS_EXIT=$?
  set -e

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

  NEEDS_ATTENTION_COUNT=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.total // 0')
  REVIEW_THREADS=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.review_threads // 0')
  REVIEW_BODIES=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.review_bodies // 0')
  ISSUE_COMMENTS=$(echo "$ANALYSIS_OUTPUT" | jq -r '.summary.issue_comments // 0')

  if [ "$NEEDS_ATTENTION_COUNT" != "0" ] && [ -n "$NEEDS_ATTENTION_COUNT" ]; then
    NEEDS_REVIEWS=true
    echo "Found $REVIEW_THREADS review threads, $REVIEW_BODIES review bodies, and $ISSUE_COMMENTS issue comments needing attention"
    echo "$ANALYSIS_OUTPUT" > "/tmp/pr-${PR_NUMBER}-analysis.json"
  else
    echo "No review comments need attention"
  fi

  # 1b. Check if rebase is needed
  echo "Checking rebase status for PR #$PR_NUMBER..."
  set +e
  BASE_BRANCH=$(check_rebase_needed "$PR_NUMBER")
  REBASE_CHECK_EXIT=$?
  set -e

  if [ $REBASE_CHECK_EXIT -eq 0 ]; then
    NEEDS_REBASE=true
    echo "PR #$PR_NUMBER needs rebase onto $BASE_BRANCH"
  elif [ $REBASE_CHECK_EXIT -eq 2 ]; then
    echo "WARNING: Failed to check rebase status (API error), skipping rebase detection"
  else
    echo "No rebase needed"
  fi

  # 1c. Check for failed CI checks (verify/unit/lint)
  if [ "${REVIEW_AGENT_ENABLE_CI_FIXES:-true}" = "true" ]; then
    echo "Checking CI status for PR #$PR_NUMBER..."
    set +e
    FAILED_CHECKS_JSON=$(get_failed_ci_checks "$PR_NUMBER")
    CI_CHECK_EXIT=$?
    set -e

    if [ $CI_CHECK_EXIT -eq 2 ]; then
      echo "WARNING: Failed to check CI status (API error), skipping CI fix detection"
      FAILED_CHECKS_JSON="[]"
    fi

    FAILED_CHECK_COUNT=$(echo "$FAILED_CHECKS_JSON" | jq 'length' 2>/dev/null || echo "0")

    if [ "$FAILED_CHECK_COUNT" -gt 0 ]; then
      NEEDS_CI_FIX=true
      echo "Found $FAILED_CHECK_COUNT failed CI checks:"
      echo "$FAILED_CHECKS_JSON" | jq -r '.[].name' 2>/dev/null | sed 's/^/  - /'
    else
      echo "No failed CI checks matching verify/unit/lint"
    fi
  fi

  # ---- SKIP if nothing to do ----
  if [ "$NEEDS_REVIEWS" = "false" ] && [ "$NEEDS_REBASE" = "false" ] && [ "$NEEDS_CI_FIX" = "false" ]; then
    echo "No reviews, rebase, or CI fixes needed for PR #$PR_NUMBER, skipping"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
    continue
  fi

  # ---- PHASE 2: CHECKOUT ----
  echo "Checking out branch: $BRANCH_NAME"
  git reset --hard HEAD
  git clean -fd
  git fetch origin "$BRANCH_NAME"
  git checkout -B "$BRANCH_NAME" "origin/$BRANCH_NAME"

  # Initialize per-PR actions JSON
  PR_ACTIONS='{"rebase":{"attempted":false},"reviews":{"attempted":false},"ci_fixes":{"attempted":false}}'
  PR_HAD_ERROR=false

  # ---- PHASE 3: REBASE (if needed) ----
  if [ "$NEEDS_REBASE" = "true" ]; then
    echo "Rebasing PR #$PR_NUMBER onto upstream/$BASE_BRANCH..."
    PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.rebase.attempted = true')
    set +e
    perform_rebase "$BASE_BRANCH"
    REBASE_EXIT=$?
    set -e

    if [ $REBASE_EXIT -ne 0 ]; then
      echo "Rebase failed for PR #$PR_NUMBER (conflicts), skipping remaining phases"
      PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.rebase.result = "conflict"')
      echo "$PR_ACTIONS" > "${SHARED_DIR}/pr-${PR_NUMBER}-actions.json"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
      echo "$PR_NUMBER $TIMESTAMP FAILED rebase_conflict" >> "$STATE_FILE"
      continue
    fi

    echo "Rebase successful"
    PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.rebase.result = "success"')
    REBASED_COUNT=$((REBASED_COUNT + 1))
  fi

  # ---- PHASE 4: REVIEWS (if needed) ----
  if [ "$NEEDS_REVIEWS" = "true" ]; then
    echo "Running: /utils:address-reviews $PR_NUMBER"
    PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.reviews.attempted = true')

    SKILL_CONTENT=$(cat /tmp/address-reviews.md)
    NEEDS_ATTENTION_JSON=$(cat "/tmp/pr-${PR_NUMBER}-analysis.json")

    REVIEW_CONTEXT="IMPORTANT: You are addressing review comments on PR #$PR_NUMBER in the openshift/hypershift repository. The PR was created from the hypershift-community fork. The gh CLI is authenticated to openshift/hypershift for reading PR information. SECURITY: Do NOT run commands that reveal git credentials. Do NOT push changes - pushing will be handled automatically after you finish.

ENVIRONMENT: The check_replied.py deduplication script is at /tmp/ai-helpers/plugins/utils/scripts/check_replied.py - use this path directly instead of relying on CLAUDE_PLUGIN_ROOT or find commands.

WITHIN-SESSION DUPLICATE PREVENTION: Before posting ANY reply:
1. At session start, run: touch /tmp/pr-${PR_NUMBER}-posted-replies.txt
2. Before each reply, check: grep -q '<comment_or_thread_id>' /tmp/pr-${PR_NUMBER}-posted-replies.txt
3. If the ID is found, SKIP that reply (already posted this session)
4. After each successful reply, run: echo '<comment_or_thread_id>' >> /tmp/pr-${PR_NUMBER}-posted-replies.txt

CRITICAL - DUPLICATE PREVENTION: The following JSON contains ONLY the comments that need your attention. These are comments where either (1) you have not replied yet, or (2) a human has replied after your last response. ONLY address these specific comments. Ignore all other threads - they have already been addressed.

COMMENTS NEEDING ATTENTION:
$NEEDS_ATTENTION_JSON

RESPONSE RULES:
1. For each piece of feedback, choose ONE response mechanism only - never respond to the same feedback via both inline reply AND general PR comment
2. Only make code changes when explicitly requested (look for imperative language like 'change', 'fix', 'update', 'remove')
3. For questions or clarifications, reply with an explanation only - do not change code unless asked
4. COMMENT LINKAGE: When replying to a flat comment (type: issue_comment or review_body), you MUST include a reference so the system knows which comment you addressed:
   - For issue_comment: include the html_url from the JSON in your reply. Format: start with 'Re: <html_url>' on its own line
   - For review_body: include the review url from the JSON in your reply. Format: start with 'Re: <url>' on its own line

${SUBAGENT_PROMPT}"

    set +e
    echo "Starting Claude review processing..."
    RESULT=$(claude -p "$PR_NUMBER. $REVIEW_CONTEXT" \
      --system-prompt "$SKILL_CONTENT" \
      --allowedTools "Bash Read Write Edit Grep Glob WebFetch" \
      --max-turns 150 \
      --effort max \
      --model "$CLAUDE_MODEL" \
      --verbose \
      --output-format stream-json \
      < /dev/null \
      2>&1 | tee "/tmp/claude-pr-${PR_NUMBER}-output.json")
    REVIEW_EXIT=$?
    set -e
    echo "Review processing complete. Output saved to /tmp/claude-pr-${PR_NUMBER}-output.json"

    if [ -f "/tmp/claude-pr-${PR_NUMBER}-output.json" ]; then
      cp "/tmp/claude-pr-${PR_NUMBER}-output.json" "${ARTIFACT_DIR}/claude-pr-${PR_NUMBER}-output.json"
      extract_claude_summary "/tmp/claude-pr-${PR_NUMBER}-output.json" "${SHARED_DIR}/claude-pr-${PR_NUMBER}-summary.json"
    fi

    if [ $REVIEW_EXIT -eq 0 ]; then
      PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.reviews.result = "success"')
      echo "Review phase succeeded for PR #$PR_NUMBER"
      echo ""
      echo "--- Claude review output for PR #$PR_NUMBER ---"
      echo "$RESULT" | tail -50
      echo "--- End Claude review output ---"
      echo ""
    else
      PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.reviews.result = "failed"')
      PR_HAD_ERROR=true
      echo "Review phase failed for PR #$PR_NUMBER"
      echo "Error output (last 20 lines):"
      echo "$RESULT" | tail -20
    fi
  fi

  # ---- PHASE 5: CI FIX (if needed and enabled) ----
  if [ "$NEEDS_CI_FIX" = "true" ] && [ "${REVIEW_AGENT_ENABLE_CI_FIXES:-true}" = "true" ]; then
    echo "Running CI fix phase for PR #$PR_NUMBER..."
    PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.ci_fixes.attempted = true')

    # Build list of failed check names for the prompt
    FAILED_CHECK_NAMES=$(echo "$FAILED_CHECKS_JSON" | jq -r '.[].name' 2>/dev/null | sed 's/^/- /')
    PR_ACTIONS=$(echo "$PR_ACTIONS" | jq --argjson checks "$FAILED_CHECKS_JSON" '.ci_fixes.checks = [$checks[].name]')

    CI_FIX_SYSTEM="You are a CI failure debugging assistant for the openshift/hypershift Go project.
You are fixing failed CI checks on PR #$PR_NUMBER.

ENVIRONMENT:
- This is a Go project. Go, make, and standard build tools are available.
- You are in the hypershift repository clone at /tmp/hypershift.
- You can reproduce failures locally using make targets and go test.

TASK:
The following CI checks are failing on this PR. Reproduce each failure locally,
diagnose the root cause, and fix the code.

APPROACH PER CHECK TYPE:
- verify: Run \`make verify\` to reproduce. Fix formatting, imports, generated
  files, or whatever the verify output indicates. Re-run to confirm the fix.
- unit: Run \`make test\` or \`go test ./path/to/package/...\` for the failing
  package. Read the test failure, fix the code or test, and re-run to confirm.
- lint/gitlint: For Go lint issues, run the linter and fix. For commit message
  lint (gitlint), fix the message with \`git commit --amend\`.

RULES:
- Do NOT push changes — pushing is handled automatically after you finish.
- After fixing each check, commit your changes with a descriptive message using
  conventional commit format (e.g., \`fix(lint): reorder imports per gci config\`).
  Amend the relevant existing commit if appropriate, or create a new fixup commit.
- Reproduce each failure first, then fix, then verify the fix passes.
- Keep changes minimal and targeted — fix only what the failing checks require.
- If a fix requires understanding broader context, use Grep/Glob/Read to
  explore the codebase before making changes.
- If you cannot fix a failure after reasonable effort, explain what you tried
  and move on to the next check."

    CI_FIX_PROMPT="Fix the following CI failures for PR #$PR_NUMBER:

Failed checks:
$FAILED_CHECK_NAMES

Reproduce each failure, fix the code, and verify the fix passes."

    set +e
    echo "Starting Claude CI fix processing..."
    CI_RESULT=$(claude -p "$CI_FIX_PROMPT" \
      --system-prompt "$CI_FIX_SYSTEM" \
      --allowedTools "Bash Read Write Edit Grep Glob" \
      --max-turns 150 \
      --effort max \
      --model "$CLAUDE_MODEL" \
      --verbose \
      --output-format stream-json \
      < /dev/null \
      2>&1 | tee "/tmp/claude-pr-${PR_NUMBER}-cifix-output.json")
    CI_FIX_EXIT=$?
    set -e
    echo "CI fix processing complete. Output saved to /tmp/claude-pr-${PR_NUMBER}-cifix-output.json"

    if [ -f "/tmp/claude-pr-${PR_NUMBER}-cifix-output.json" ]; then
      cp "/tmp/claude-pr-${PR_NUMBER}-cifix-output.json" "${ARTIFACT_DIR}/claude-pr-${PR_NUMBER}-cifix-output.json"
      extract_claude_summary "/tmp/claude-pr-${PR_NUMBER}-cifix-output.json" "${SHARED_DIR}/claude-pr-${PR_NUMBER}-cifix-summary.json"
    fi

    if [ $CI_FIX_EXIT -eq 0 ]; then
      PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.ci_fixes.result = "success"')
      CI_FIX_COUNT=$((CI_FIX_COUNT + 1))
      echo "CI fix phase succeeded for PR #$PR_NUMBER"
    else
      PR_ACTIONS=$(echo "$PR_ACTIONS" | jq '.ci_fixes.result = "failed"')
      PR_HAD_ERROR=true
      echo "CI fix phase failed for PR #$PR_NUMBER"
      echo "Error output (last 20 lines):"
      echo "$CI_RESULT" | tail -20
    fi
  fi

  # ---- PHASE 6: PUSH (single push at end if any phase made changes) ----
  # Commit any uncommitted changes left by Claude (safety net)
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "Committing uncommitted changes left by Claude for PR #$PR_NUMBER..."
    git add -A
    git commit -m "fix: address CI check failures

Automated fix for failing CI checks on PR #$PR_NUMBER.

Co-Authored-By: Claude <noreply@anthropic.com>"
  fi

  PUSH_NEEDED=false
  if ! git diff --quiet HEAD "origin/$BRANCH_NAME" 2>/dev/null; then
    PUSH_NEEDED=true
  fi

  if [ "$NEEDS_REBASE" = "true" ]; then
    # Rebase always requires a push even if no file diff (history changed)
    PUSH_NEEDED=true
  fi

  if [ "$PR_HAD_ERROR" = "true" ]; then
    echo "Skipping push for PR #$PR_NUMBER because an earlier phase failed"
  elif [ "$PUSH_NEEDED" = "true" ]; then
    echo "Pushing changes for PR #$PR_NUMBER..."
    set +e
    git push --force-with-lease origin "$BRANCH_NAME"
    PUSH_EXIT=$?
    set -e

    if [ $PUSH_EXIT -eq 0 ]; then
      echo "Push completed for PR #$PR_NUMBER"
    else
      echo "Push failed for PR #$PR_NUMBER"
      PR_HAD_ERROR=true
    fi
  else
    echo "No changes to push for PR #$PR_NUMBER"
  fi

  # ---- Write per-PR actions JSON ----
  echo "$PR_ACTIONS" > "${SHARED_DIR}/pr-${PR_NUMBER}-actions.json"

  if [ "$PR_HAD_ERROR" = "true" ]; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "$PR_NUMBER $TIMESTAMP FAILED" >> "$STATE_FILE"
  else
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    echo "$PR_NUMBER $TIMESTAMP SUCCESS" >> "$STATE_FILE"
  fi

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
echo "Skipped (no action needed): $SKIPPED_COUNT"
echo "Rebased: $REBASED_COUNT"
echo "CI Fixes: $CI_FIX_COUNT"
echo "Failed: $FAILED_COUNT"
echo "=========================="
