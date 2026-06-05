#!/bin/bash
# Analyze PR validation failures and fetch error logs
# Usage: analyze-validation.sh <PR_NUMBER>
#
# Example:
#   analyze-validation.sh 79996

set -euo pipefail

PR_NUM="${1:?PR number required}"

echo "=== Analyzing Validation Failures for PR #${PR_NUM} ==="
echo ""

# Get all PR checks
CHECKS=$(gh pr checks "${PR_NUM}" --repo openshift/release 2>&1)

# Find failing validation checks
FAILING_CHECKS=$(echo "${CHECKS}" | grep -E "owners|metadata|shellcheck|ci-operator-registry" | grep "fail" || echo "")

if [[ -z "${FAILING_CHECKS}" ]]; then
  echo "✅ No failing validation checks found"
  exit 0
fi

echo "Found failing checks:"
echo "${FAILING_CHECKS}"
echo ""

# Analyze each failure
echo "${FAILING_CHECKS}" | while read -r LINE; do
  CHECK_NAME=$(echo "${LINE}" | awk '{print $1}')
  CHECK_URL=$(echo "${LINE}" | awk '{print $4}')

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "❌ ${CHECK_NAME}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  if [[ -z "${CHECK_URL}" || "${CHECK_URL}" == "-" ]]; then
    echo "No URL available for this check"
    echo ""
    continue
  fi

  # Convert Prow URL to GCS web URL for build log
  GCS_URL=$(echo "${CHECK_URL}" | sed 's|https://prow.ci.openshift.org/view/gs/|https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/|')
  BUILD_LOG_URL="${GCS_URL}/build-log.txt"

  echo "Fetching build log..."
  echo "URL: ${BUILD_LOG_URL}"
  echo ""

  # Fetch and display last 50 lines of build log
  curl -sL "${BUILD_LOG_URL}" | tail -50 || echo "Failed to fetch build log"

  echo ""
  echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Analysis complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
