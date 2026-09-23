#!/bin/bash
set -euo pipefail

# Write the slack-pr-notify shell library to SHARED_DIR for the process step to source.
cat > "${SHARED_DIR}/slack-pr-notify.sh" << 'EOF'
#!/bin/bash
# Send a Slack notification when a CI job creates a pull request.
#
# Usage:
#   source slack-pr-notify.sh
#   send_slack_notification <pr_url> <pr_number>
#
# Environment (required):
#   SLACK_WEBHOOK_URL         Incoming webhook URL (empty to skip).
#   JIRA_AGENT_UPSTREAM_REPO  Repo slug for gh pr view (e.g. openshift/hypershift).
#   GITHUB_SLACK_MAP          JSON mapping GitHub usernames to Slack user IDs.
#                             Include a "backup-user" key as fallback.
#
# Environment (optional):
#   SLACK_EMOJI               Message prefix emoji (default: :robot:).

: "${SLACK_EMOJI:=:robot:}"

# ---------------------------------------------------------------------------
# Internal helpers — not part of the public API.
# ---------------------------------------------------------------------------

# _slack_log <message>
_slack_log() { echo "   $1"; }

# _poll_reviewers <pr_number>
#   Polls gh pr view for up to 2 minutes waiting for reviewers.
#   Sets _REVIEWERS (newline-separated logins) and _PR_TITLE.
_poll_reviewers() {
  local pr_num="$1"
  local attempt=0 max_attempts=5 pr_data

  _REVIEWERS=""
  _PR_TITLE=""

  while (( attempt < max_attempts )); do
    pr_data=$(gh pr view "$pr_num" \
      --repo "${JIRA_AGENT_UPSTREAM_REPO}" \
      --json reviewRequests,title 2>/dev/null || echo "{}")

    _PR_TITLE=$(echo "$pr_data" | jq -r '.title // empty' 2>/dev/null) || true
    _REVIEWERS=$(echo "$pr_data" | jq -r '.reviewRequests[]?.login // empty' 2>/dev/null) || true

    if [[ -n "$_REVIEWERS" ]]; then
      _slack_log "Reviewers found: $_REVIEWERS"
      return
    fi

    (( attempt++ ))
    if (( attempt < max_attempts )); then
      _slack_log "No reviewers yet, retrying in 30s (attempt ${attempt}/${max_attempts})..."
      sleep 30
    fi
  done
}

# _build_mentions
#   Reads _REVIEWERS and GITHUB_SLACK_MAP, writes _MENTIONS string.
#   Falls back to backup-user when no reviewers are assigned.
_build_mentions() {
  local map="${GITHUB_SLACK_MAP:-{}}"
  _MENTIONS=""

  if [[ -n "$_REVIEWERS" ]]; then
    local gh_user slack_id
    while IFS= read -r gh_user; do
      slack_id=$(echo "$map" | jq -r --arg u "$gh_user" '.[$u] // empty' 2>/dev/null) || true
      if [[ -n "$slack_id" ]]; then
        _MENTIONS+=" <@${slack_id}>"
      else
        _MENTIONS+=" ${gh_user}"
      fi
    done <<< "$_REVIEWERS"
  else
    _slack_log "No reviewers assigned after polling, using fallback"
    local fallback_id
    fallback_id=$(echo "$map" | jq -r '.["backup-user"] // empty' 2>/dev/null) || true
    if [[ -n "$fallback_id" ]]; then
      _MENTIONS="<@${fallback_id}>"
    else
      _MENTIONS="(none assigned)"
    fi
  fi

  _MENTIONS="${_MENTIONS# }"
}

# _post_webhook <json_payload>
#   Posts to SLACK_WEBHOOK_URL, suppressing set -x to avoid leaking the URL.
#   Never fatal — returns 0 regardless of outcome.
_post_webhook() {
  local payload="$1"

  local was_tracing=false was_errexit=false
  [[ $- == *x* ]] && was_tracing=true
  [[ $- == *e* ]] && was_errexit=true
  set +x
  set +e

  local response http_code
  response=$(curl -s -w "\n%{http_code}" -X POST \
    --connect-timeout 10 --max-time 20 \
    -H 'Content-type: application/json' \
    --data "$payload" \
    "$SLACK_WEBHOOK_URL")
  local rc=$?

  $was_errexit && set -e
  $was_tracing && set -x

  if [[ $rc -ne 0 ]]; then
    _slack_log "Warning: Slack notification failed (curl exit $rc)"
    return 0
  fi

  http_code=$(echo "$response" | tail -1)
  if [[ "$http_code" == "200" ]]; then
    _slack_log "Slack notification sent"
  else
    _slack_log "Warning: Slack notification failed (HTTP $http_code)"
  fi
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# send_slack_notification <pr_url> <pr_number>
#
# Polls for PR reviewers, maps GitHub usernames to Slack IDs, and posts a
# formatted message to the configured webhook. Safe to call unconditionally —
# skips when SLACK_WEBHOOK_URL is empty, never fails the job.
send_slack_notification() {
  local pr_url="$1" pr_num="$2"

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    _slack_log "Skipping Slack notification (no webhook configured)"
    return 0
  fi

  _slack_log "Polling for PR reviewers (up to 2 minutes)..."
  _poll_reviewers "$pr_num"

  : "${_PR_TITLE:=PR #${pr_num}}"

  _build_mentions

  local safe_title
  safe_title=$(printf '%s' "$_PR_TITLE" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

  local payload
  payload=$(jq -n \
    --arg title "$safe_title" \
    --arg url   "$pr_url" \
    --arg revs  "$_MENTIONS" \
    --arg emoji "$SLACK_EMOJI" \
    '{text: "\($emoji) *Jira Agent PR ready for review*\n:review: <\($url)|\($title)>\n:eyes: Reviewers: \($revs)"}')

  _post_webhook "$payload"
}
EOF

echo "slack-pr-notify.sh written to SHARED_DIR"
