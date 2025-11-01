#!/bin/bash
set -euo pipefail

echo "=== HyperShift Jira Agent Report ==="

STATE_FILE="/tmp/processed-issues.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file found, nothing to report"
  exit 0
fi

# Load state
TOTAL_LINES=$(wc -l < "$STATE_FILE" || echo "0")
SUCCESS_COUNT=$(grep -c "SUCCESS$" "$STATE_FILE" || echo "0")
FAILED_COUNT=$(grep -c "FAILED$" "$STATE_FILE" || echo "0")

echo "Total issues in state: $TOTAL_LINES"
echo "Successful: $SUCCESS_COUNT"
echo "Failed: $FAILED_COUNT"

# Show recent successes (last 5)
echo ""
echo "Recent successful PRs:"
grep "SUCCESS$" "$STATE_FILE" | tail -5 | while read -r line; do
  ISSUE=$(echo "$line" | awk '{print $1}')
  PR=$(echo "$line" | awk '{print $3}')
  echo "  - $ISSUE: $PR"
done

# Show recent failures (last 5)
echo ""
echo "Recent failures:"
grep "FAILED$" "$STATE_FILE" | tail -5 | while read -r line; do
  ISSUE=$(echo "$line" | awk '{print $1}')
  TIMESTAMP=$(echo "$line" | awk '{print $2}')
  echo "  - $ISSUE at $TIMESTAMP"
done

echo ""
echo "=== Report Complete ==="

# TODO: Add Slack notification, metrics push, etc.
