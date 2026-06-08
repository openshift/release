#!/bin/bash
# Trigger a /pj-rehearse job by commenting on a PR
set -euo pipefail

PR="${1:?PR number required}"
JOB_NAME="${2:?Job name required}"

echo "[trigger-rehearsal] Triggering rehearsal for PR #${PR}: ${JOB_NAME}"

# Use gh to post comment with /pj-rehearse command
gh pr comment "${PR}" --repo openshift/release --body "/pj-rehearse ${JOB_NAME}"

echo "[trigger-rehearsal] Rehearsal triggered. Waiting 60s for Prow to process..."
sleep 60

# Check for rejection
echo "[trigger-rehearsal] Checking for rehearsal rejection..."
REJECTION=$(gh pr view "${PR}" --repo openshift/release --comments 2>/dev/null | tail -30 | grep -i "cannot be rehearsed" || true)

if [[ -n "$REJECTION" ]]; then
  echo ""
  echo "❌ REHEARSAL REJECTED!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$REJECTION"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Common causes:"
  echo "1. Job not in affected list (run: .claude/scripts/list-affected-jobs.sh ${PR})"
  echo "2. Jobs file not regenerated (env var changes don't trigger job updates)"
  echo "3. Wrong job name (check for typos or version mismatches)"
  echo ""
  echo "To fix:"
  echo "- Make a structural change (timeout, workflow, etc.) to the config"
  echo "- Run: make jobs"
  echo "- Verify: git diff ci-operator/jobs/"
  echo "- Commit, push, wait for validation"
  echo "- Retry trigger"
  exit 1
else
  echo "✅ No rejection detected. Rehearsal should be starting."
  echo "[trigger-rehearsal] Check status with: .claude/scripts/prow-fetch.sh pr-checks ${PR}"
fi
