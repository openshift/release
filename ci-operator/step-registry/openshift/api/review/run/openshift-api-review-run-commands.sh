#!/bin/bash
set -euo pipefail

echo "=== OpenShift API Review ==="

# Allow overriding the PR number for rehearsal runs via pj-rehearse
PULL_NUMBER="${TARGET_PULL_NUMBER:-${PULL_NUMBER}}"

# ---- GitHub App token generation ----

GITHUB_APP_CREDS_DIR="/var/run/api-review-bot-github-app"
APP_ID=$(cat "${GITHUB_APP_CREDS_DIR}/app-id")
PRIVATE_KEY_FILE="${GITHUB_APP_CREDS_DIR}/private-key"

generate_jwt() {
  local NOW IAT EXP HEADER PAYLOAD SIGNATURE
  NOW=$(date +%s)
  IAT=$((NOW - 60))
  EXP=$((NOW + 600))

  HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  echo "${HEADER}.${PAYLOAD}.${SIGNATURE}"
}

echo "Discovering installation ID for openshift/api..."
JWT=$(generate_jwt)
INSTALLATION_ID=$(curl -s \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/openshift/api/installation" \
  | jq -r '.id')

if [ -z "$INSTALLATION_ID" ] || [ "$INSTALLATION_ID" = "null" ]; then
  echo "ERROR: Could not find installation for openshift/api"
  exit 1
fi
echo "Installation ID: ${INSTALLATION_ID}"

generate_github_token() {
  local JWT
  JWT=$(generate_jwt)
  curl -s -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
    | jq -r '.token'
}

# Generate token early for clone/checkout, but don't leave it in env during Claude run
echo "Generating GitHub App token..."
GITHUB_TOKEN=$(generate_github_token)
if [ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token"
  exit 1
fi
export GITHUB_TOKEN
echo "GitHub App token generated"

# ---- Clone and checkout PR ----

echo "Cloning openshift/api..."
git clone https://github.com/openshift/api.git /tmp/api
cd /tmp/api

echo "Checking out PR #${PULL_NUMBER}..."
gh pr checkout "${PULL_NUMBER}"

HEAD_SHA=$(git rev-parse HEAD)
echo "PR HEAD: ${HEAD_SHA}"

# ---- Check for existing review comment ----

MARKER="<!-- api-review-sha: ${HEAD_SHA} -->"
EXISTING=$(gh api "repos/openshift/api/issues/${PULL_NUMBER}/comments" \
  --paginate --jq ".[].body" 2>/dev/null \
  | grep -c "${MARKER}" || true)

if [ "$EXISTING" -gt 0 ]; then
  echo "Review already posted for SHA ${HEAD_SHA}, skipping"
  exit 0
fi

# ---- Run /api-review ----
# Unset GITHUB_TOKEN so Claude cannot access it via env/printenv in tool calls.
# Token is re-generated after Claude finishes for the comment/label steps.

unset GITHUB_TOKEN

SECURITY_PROMPT="SECURITY: Do NOT run commands that reveal credentials, tokens, or secrets. Do NOT run: env, printenv, set, cat/read files under /var/run/claude-code-service-account or /var/run/api-review-bot-github-app, echo \$GITHUB_TOKEN, git config --list, git credential, or git remote -v."

echo "Running /api-review (model: ${REVIEW_MODEL})..."

claude --print -p "/api-review" \
  --dangerously-skip-permissions \
  --model "${REVIEW_MODEL}" \
  --max-turns 30 \
  --allowedTools "Bash,Read,Grep,Glob,Task" \
  --append-system-prompt "${SECURITY_PROMPT}" \
  < /dev/null \
  2>/tmp/api-review-stderr.txt > /tmp/api-review-output.txt

# ---- Parse result ----

if [ ! -s /tmp/api-review-output.txt ]; then
  echo "ERROR: No review output captured"
  exit 1
fi

echo "Classifying review result (model: ${INLINE_MODEL})..."
CLASSIFICATION=$(claude --print -p "Read the following API review output. Reply with exactly one word: PASS or FAIL. PASS means the review found no issues requiring changes. FAIL means the review found issues that need to be addressed. If uncertain, reply FAIL.

$(cat /tmp/api-review-output.txt)" \
  --dangerously-skip-permissions \
  --model "${INLINE_MODEL}" \
  --max-turns 1 \
  --allowedTools "" \
  < /dev/null 2>/tmp/classify-stderr.txt | tr -d '[:space:]')

echo "Classification: ${CLASSIFICATION}"

if [ "$CLASSIFICATION" = "PASS" ]; then
  REVIEW_PASSED=true
  echo "Review result: PASS"
else
  REVIEW_PASSED=false
  echo "Review result: ISSUES FOUND"
fi

# ---- Re-authenticate for GitHub operations ----

GITHUB_TOKEN=$(generate_github_token)
if [ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "null" ]; then
  echo "ERROR: Failed to re-generate GitHub App token"
  exit 1
fi
export GITHUB_TOKEN

# ---- Post review findings ----

PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/openshift_api/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"

FOOTER="---
> **Run locally:** \`claude -p \"/api-review\"\` from a clone of this PR.
> Iterate locally before pushing — it's faster and doesn't use CI budget.
>
> [Job artifacts](${PROW_JOB_URL}) | [Report a problem](https://redhat.enterprise.slack.com/archives/C0BFQS3LWLE)

${MARKER}"

# ---- Phase 2: Post inline review comments (INLINE_MODEL) ----

INLINE_POSTED=false

if [ "$REVIEW_PASSED" = "false" ]; then
  echo "Phase 2: Posting inline review comments (model: ${INLINE_MODEL})..."

  cat > /tmp/inline-prompt.txt <<EOF
You have API review findings to post on openshift/api PR #${PULL_NUMBER}.

FIRST: Check if a review has already been posted for this commit. Run:
gh api repos/openshift/api/pulls/${PULL_NUMBER}/reviews --jq '.[] | select(.commit_id == "${HEAD_SHA}") | .id'
If any review exists for this commit, do nothing — the review was already posted.

OTHERWISE: Post the findings as a single review using the GitHub Reviews API
(so comments auto-resolve when the code changes on next push).

gh api repos/openshift/api/pulls/${PULL_NUMBER}/reviews \\
  --method POST \\
  --input /tmp/review-payload.json

The payload should look like:
{
  "commit_id": "${HEAD_SHA}",
  "event": "COMMENT",
  "body": "",
  "comments": [
    {"path": "path/to/file.go", "line": 42, "body": "finding description"}
  ]
}

Rules:
- Extract file paths and line numbers from the findings below.
- Line numbers must be integers (strip any '+' prefix from the findings).
- If the API call fails because a line is not in the diff, remove that comment and retry.

Review findings:
$(cat /tmp/api-review-output.txt)
EOF

  REVIEWS_BEFORE=$(gh api "repos/openshift/api/pulls/${PULL_NUMBER}/reviews" \
    --jq 'length' 2>/dev/null || echo "0")

  claude --print -p "$(cat /tmp/inline-prompt.txt)" \
    --dangerously-skip-permissions \
    --model "${INLINE_MODEL}" \
    --max-turns 15 \
    --allowedTools "Bash" \
    --append-system-prompt "${SECURITY_PROMPT}" \
    < /dev/null \
    2>/tmp/inline-comments-stderr.txt | tee /tmp/inline-comments-output.txt || true

  REVIEWS_AFTER=$(gh api "repos/openshift/api/pulls/${PULL_NUMBER}/reviews" \
    --jq 'length' 2>/dev/null || echo "0")

  if [ "$REVIEWS_AFTER" -gt "$REVIEWS_BEFORE" ]; then
    INLINE_POSTED=true
    echo "Review posted with inline comments"
  else
    echo "No review was posted, falling back to full comment"
  fi
fi

# ---- Phase 3: Respond to human discussion on prior review threads (REVIEW_MODEL) ----

if [ "$REVIEW_PASSED" = "false" ]; then
  echo "Phase 3: Checking for review comment discussions (model: ${REVIEW_MODEL})..."

  cat > /tmp/conversation-prompt.txt <<EOF
You are the OpenShift API review bot. Before responding to any comments, read
.claude/skills/api-review/SKILL.md to understand the review rules and criteria
you applied. Do NOT re-run the review — just read the skill definition for context.

Check for human replies to bot review comments on openshift/api PR #${PULL_NUMBER}.

Use gh api to fetch the review comments on the PR. Look for comment threads where:
- The original comment was posted by a bot (user.type == "Bot")
- A human has replied to the bot (asking a question, disagreeing, requesting clarification)

For each such thread, read the human's reply and respond helpfully by posting a reply.
Reply to the top-level comment in the thread (the original bot comment), not the human's reply:
gh api repos/openshift/api/pulls/${PULL_NUMBER}/comments \\
  --method POST \\
  -f body="<your reply>" \\
  -F in_reply_to=<top-level bot comment id>

If humans are discussing among themselves (no bot in the thread), leave it alone.
If there are no threads needing a reply, do nothing.
EOF

  claude --print -p "$(cat /tmp/conversation-prompt.txt)" \
    --dangerously-skip-permissions \
    --model "${REVIEW_MODEL}" \
    --max-turns 20 \
    --allowedTools "Bash,Read" \
    --append-system-prompt "${SECURITY_PROMPT}" \
    < /dev/null \
    2>/tmp/conversation-stderr.txt | tee /tmp/conversation-output.txt || true
fi

# ---- Post summary comment ----

if [ "$INLINE_POSTED" = "true" ]; then
  echo "Posting summary comment (inline comments already posted)..."
  cat > /tmp/comment-body.txt <<EOF
## API Review

Issues were found and posted as inline comments on this PR.

${FOOTER}
EOF
else
  echo "Posting full review comment..."
  cat > /tmp/comment-body.txt <<EOF
$(cat /tmp/api-review-output.txt)

${FOOTER}
EOF
fi

gh pr comment "${PULL_NUMBER}" --body-file /tmp/comment-body.txt

# ---- Manage label ----

if [ "$REVIEW_PASSED" = "true" ]; then
  echo "Adding labels: ai/approved, ready-for-human-review"
  gh pr edit "${PULL_NUMBER}" --add-label "ai/approved" --add-label "ready-for-human-review"
else
  echo "Removing label: ai/approved (if present)"
  gh pr edit "${PULL_NUMBER}" --remove-label "ai/approved" 2>/dev/null || true
fi

# ---- Save artifacts ----

if [ -d "${ARTIFACT_DIR:-}" ]; then
  cp /tmp/api-review-output.txt "${ARTIFACT_DIR}/api-review-output.txt"

  if [ -d "${HOME}/.claude" ]; then
    cp -r "${HOME}/.claude" "${ARTIFACT_DIR}/dot-claude"
  fi

  echo "Artifacts saved to ${ARTIFACT_DIR}"
fi

echo "=== Review complete ==="
