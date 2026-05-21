#\!/bin/bash
# Trigger a /pj-rehearse job by commenting on a PR
set -euo pipefail

PR="${1:?PR number required}"
JOB_NAME="${2:?Job name required}"

echo "[trigger-rehearsal] Triggering rehearsal for PR #${PR}: ${JOB_NAME}"

# Use gh to post comment with /pj-rehearse command
gh pr comment "${PR}" --repo openshift/release --body "/pj-rehearse ${JOB_NAME}"

echo "[trigger-rehearsal] Rehearsal triggered. Allow up to 10 minutes for Prow to process."
echo "[trigger-rehearsal] Check status with: .claude/scripts/prow-fetch.sh pr-checks ${PR}"
