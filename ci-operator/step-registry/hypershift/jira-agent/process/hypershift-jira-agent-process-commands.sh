#!/bin/bash
set -euo pipefail

echo "=== HyperShift Jira Agent Process ==="

cd /tmp/hypershift

# Export credentials
export ANTHROPIC_API_KEY=$(cat /var/run/vault/hypershift-jira-agent-anthropic-api-key/key)
export GITHUB_TOKEN=$(cat /var/run/vault/hypershift-jira-agent-github-token/token)

# GitHub CLI auth
gh auth login --with-token <<< "$GITHUB_TOKEN"

# Configuration: maximum issues to process per run (default: 10)
MAX_ISSUES=${JIRA_AGENT_MAX_ISSUES:-10}
echo "Configuration: MAX_ISSUES=$MAX_ISSUES"

# Query Jira for issues
echo "Querying Jira for issues..."
ISSUES=$(curl -s "https://issues.redhat.com/rest/api/2/search" \
  -G \
  --data-urlencode 'jql=project in (OCPBUGS, CNTRLPLANE) AND resolution = Unresolved AND labels = issue-for-agent' \
  --data-urlencode 'fields=key,summary' \
  --data-urlencode "maxResults=$MAX_ISSUES" \
  | jq -r '.issues[]? | "\(.key) \(.fields.summary)"')

if [ -z "$ISSUES" ]; then
  echo "No issues found matching criteria"
  exit 0
fi

echo "Found issues:"
echo "$ISSUES" | awk '{print "  - " $1}'

# Load processed issues state from ConfigMap
STATE_FILE="/tmp/processed-issues.txt"
echo "Loading state from ConfigMap..."
kubectl get configmap hypershift-jira-agent-state -n ci -o jsonpath='{.data.processed}' > "$STATE_FILE" 2>/dev/null || touch "$STATE_FILE"

PROCESSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
TOTAL_PROCESSED_OR_FAILED=0

# Process each issue
while IFS= read -r line; do
  # Stop if we've reached the max issues limit (counting both successful and failed)
  if [ $TOTAL_PROCESSED_OR_FAILED -ge $MAX_ISSUES ]; then
    echo "Reached maximum issues limit ($MAX_ISSUES). Stopping."
    break
  fi
  ISSUE_KEY=$(echo "$line" | awk '{print $1}')
  ISSUE_SUMMARY=$(echo "$line" | cut -d' ' -f2-)

  # Skip if already processed
  if grep -q "^$ISSUE_KEY " "$STATE_FILE"; then
    echo "⏭️  Skipping already processed issue: $ISSUE_KEY"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  echo ""
  echo "=========================================="
  echo "Processing: $ISSUE_KEY"
  echo "Summary: $ISSUE_SUMMARY"
  echo "=========================================="

  # Run /jira-solve command non-interactively
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  set +e  # Don't exit on error for individual issues
  RESULT=$(echo "/jira-solve $ISSUE_KEY origin" | claude -p \
    --output-format json \
    --dangerously-skip-permissions \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch SlashCommand" \
    --max-turns 30 \
    2>&1)
  EXIT_CODE=$?
  set -e

  if [ $EXIT_CODE -eq 0 ]; then
    # Parse PR URL from result if available
    PR_URL=$(echo "$RESULT" | jq -r '.result' 2>/dev/null | grep -oP 'https://github.com/openshift/hypershift/pull/[0-9]+' | head -1 || echo "")

    # Record success
    echo "$ISSUE_KEY $TIMESTAMP $PR_URL SUCCESS" >> "$STATE_FILE"
    echo "✅ Successfully processed $ISSUE_KEY"
    if [ -n "$PR_URL" ]; then
      echo "   PR: $PR_URL"
    fi
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
  else
    # Record failure
    echo "$ISSUE_KEY $TIMESTAMP - FAILED" >> "$STATE_FILE"
    echo "❌ Failed to process $ISSUE_KEY"
    echo "Error output (last 20 lines):"
    echo "$RESULT" | tail -20
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi

  # Increment total counter
  TOTAL_PROCESSED_OR_FAILED=$((TOTAL_PROCESSED_OR_FAILED + 1))

  # Rate limiting between issues (60 seconds)
  # Skip sleep if we've reached the limit
  if [ $TOTAL_PROCESSED_OR_FAILED -lt $MAX_ISSUES ]; then
    echo "Waiting 60 seconds before next issue..."
    sleep 60
  fi

done <<< "$ISSUES"

# Update state ConfigMap
echo ""
echo "Updating state ConfigMap..."
kubectl create configmap hypershift-jira-agent-state -n ci \
  --from-file=processed="$STATE_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Processing Summary ==="
echo "Processed: $PROCESSED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "Skipped (already processed): $SKIPPED_COUNT"
echo "=========================="
