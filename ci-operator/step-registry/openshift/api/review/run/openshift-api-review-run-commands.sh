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

echo "Running /api-review (model: ${REVIEW_MODEL})..."

claude --print -p "/api-review" \
  --dangerously-skip-permissions \
  --model "${REVIEW_MODEL}" \
  --max-turns 30 \
  --allowedTools "Bash,Read,Grep,Glob,Task" \
  < /dev/null \
  2>/tmp/api-review-stderr.txt > /tmp/api-review-output.txt

# ---- Parse result ----

if [ ! -s /tmp/api-review-output.txt ]; then
  echo "ERROR: No review output captured"
  exit 1
fi

if grep -q '^RESULT:PASS$' /tmp/api-review-output.txt; then
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

INLINE_POSTED=false

if [ "$REVIEW_PASSED" = "false" ]; then
  echo "Posting inline review comments (model: ${INLINE_MODEL})..."

  cat > /tmp/inline-prompt.txt <<EOF
You have API review findings that include file paths and line numbers.
Post each finding as an inline PR review comment on openshift/api PR #${PULL_NUMBER}.

For each finding, run:
gh api repos/openshift/api/pulls/${PULL_NUMBER}/comments \\
  --method POST \\
  -f commit_id=${HEAD_SHA} \\
  -f path=<file path> \\
  -F line=<line number, digits only, no + prefix> \\
  -f side=RIGHT \\
  -f subject_type=line \\
  -f body=<the finding description, suggested fix, and explanation>

Extract the file path and line number from lines like 'path/to/file.go:+42: description'.
Strip the '+' prefix from the line number before passing it to the API.

If a gh api call fails (e.g. line not in diff), skip that finding and continue with the rest.

Review findings:
$(cat /tmp/api-review-output.txt)
EOF

  COMMENTS_BEFORE=$(gh api "repos/openshift/api/pulls/${PULL_NUMBER}/comments" \
    --paginate --jq 'length' 2>/dev/null | awk '{s+=$1} END {print s+0}')

  claude --print -p "$(cat /tmp/inline-prompt.txt)" \
    --dangerously-skip-permissions \
    --model "${INLINE_MODEL}" \
    --max-turns 15 \
    --allowedTools "Bash" \
    < /dev/null \
    2>/tmp/inline-comments-stderr.txt | tee /tmp/inline-comments-output.txt || true

  COMMENTS_AFTER=$(gh api "repos/openshift/api/pulls/${PULL_NUMBER}/comments" \
    --paginate --jq 'length' 2>/dev/null | awk '{s+=$1} END {print s+0}')

  if [ "$COMMENTS_AFTER" -gt "$COMMENTS_BEFORE" ]; then
    INLINE_POSTED=true
    echo "Inline comments posted: $((COMMENTS_AFTER - COMMENTS_BEFORE)) new comments"
  else
    echo "No inline comments were posted, falling back to full comment"
  fi
fi

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
  echo "Adding label: ai/approved"
  gh pr edit "${PULL_NUMBER}" --add-label "ai/approved" || true
else
  echo "Removing label: ai/approved (if present)"
  gh pr edit "${PULL_NUMBER}" --remove-label "ai/approved" || true
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
