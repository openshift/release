#!/bin/bash
# List jobs affected by PR changes (using /pj-rehearse list)
# Usage: list-affected-jobs.sh <PR_NUMBER> [FILTER]
#
# Examples:
#   # List all affected jobs
#   list-affected-jobs.sh 79996
#
#   # Filter for specific job pattern
#   list-affected-jobs.sh 79996 "azure-ipi-coco"

set -euo pipefail

PR_NUM="${1:?PR number required}"
FILTER="${2:-}"

echo "=== Requesting Affected Jobs List for PR #${PR_NUM} ==="

# Post /pj-rehearse list command
gh pr comment "${PR_NUM}" --repo openshift/release --body "/pj-rehearse list" > /dev/null
echo "Comment posted. Waiting for Prow response..."
echo ""

# Wait for Prow to respond (usually takes 5-15 seconds)
sleep 10

# Fetch recent comments to find the list
COMMENTS=$(gh pr view "${PR_NUM}" --repo openshift/release --comments 2>&1)

# Extract the affected jobs table
JOBS_TABLE=$(echo "${COMMENTS}" | awk '/Test name.*Repo.*Type.*Reason/,/^--$/' | grep -v "^--$" || echo "")

if [[ -z "${JOBS_TABLE}" ]]; then
  echo "⏳ Prow hasn't responded yet. Try again in a few seconds or check PR comments manually:"
  echo "https://github.com/openshift/release/pull/${PR_NUM}"
  exit 1
fi

echo "Affected Jobs:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -n "${FILTER}" ]]; then
  echo "Filtering for: ${FILTER}"
  echo ""
  echo "${JOBS_TABLE}" | grep -i "${FILTER}" || echo "No jobs matching filter: ${FILTER}"
else
  echo "${JOBS_TABLE}"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Extract just job names for easy copy-paste
echo ""
echo "Job Names Only (for /pj-rehearse):"
echo ""

if [[ -n "${FILTER}" ]]; then
  echo "${JOBS_TABLE}" | grep -i "${FILTER}" | awk '{print $1}' | grep -v "Test" || echo "No matches"
else
  echo "${JOBS_TABLE}" | awk '{print $1}' | grep -v "Test" | grep "^periodic-" || echo "No job names found"
fi
