#!/bin/bash
# Monitor PR validation checks until all pass or fail
# Usage: monitor-validation.sh <PR_NUMBER> [MAX_CHECKS] [CHECK_INTERVAL]
#
# Examples:
#   # Monitor with defaults (30 checks, 2 min interval = 60 min max)
#   monitor-validation.sh 79996
#
#   # Custom: 20 checks every 90 seconds
#   monitor-validation.sh 79996 20 90

set -euo pipefail

# Parse arguments
PR_NUM="${1:?PR number required}"
MAX_CHECKS="${2:-30}"           # Default: 30 checks
CHECK_INTERVAL="${3:-120}"      # Default: 2 minutes

echo "=== Validation Monitor ==="
echo "PR: https://github.com/openshift/release/pull/${PR_NUM}"
echo "Max checks: ${MAX_CHECKS}"
echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

# Key validation checks to monitor
VALIDATION_CHECKS=(
  "ci/prow/owners"
  "ci/prow/step-registry-metadata"
  "ci/prow/step-registry-shellcheck"
  "ci/prow/ci-operator-registry"
)

for ((i=1; i<=MAX_CHECKS; i++)); do
  echo "⏳ Check $i/$(MAX_CHECKS) - $(date '+%Y-%m-%d %H:%M:%S')"

  # Get PR checks
  CHECKS=$(gh pr checks "${PR_NUM}" --repo openshift/release 2>&1 || echo "")

  if [[ -z "${CHECKS}" ]]; then
    echo "  WARNING: Unable to fetch PR checks"
    sleep "${CHECK_INTERVAL}"
    continue
  fi

  # Count status for each validation check
  TOTAL=0
  PASSING=0
  FAILING=0
  PENDING=0

  for CHECK in "${VALIDATION_CHECKS[@]}"; do
    STATUS=$(echo "${CHECKS}" | grep "^${CHECK}" | awk '{print $2}' || echo "unknown")

    if [[ "${STATUS}" == "pass" ]]; then
      ((PASSING++)) || true
      echo "  ✅ ${CHECK}"
    elif [[ "${STATUS}" == "fail" ]]; then
      ((FAILING++)) || true
      echo "  ❌ ${CHECK}"

      # Get failure URL for analysis
      FAIL_URL=$(echo "${CHECKS}" | grep "^${CHECK}" | awk '{print $4}' || echo "")
      if [[ -n "${FAIL_URL}" ]]; then
        echo "     URL: ${FAIL_URL}"
      fi
    elif [[ "${STATUS}" == "pending" ]]; then
      ((PENDING++)) || true
      echo "  ⏳ ${CHECK}"
    else
      echo "  ❓ ${CHECK} (status: ${STATUS})"
    fi

    ((TOTAL++)) || true
  done

  echo ""
  echo "  Summary: ${PASSING}/${TOTAL} passing, ${FAILING} failing, ${PENDING} pending"
  echo ""

  # Check if all passing
  if [[ ${PASSING} -eq ${TOTAL} ]]; then
    echo "✅ All validation checks PASSED!"
    exit 0
  fi

  # Check if any failing
  if [[ ${FAILING} -gt 0 ]]; then
    echo "❌ Found ${FAILING} failing check(s)!"
    echo ""
    echo "Action required: Analyze and fix failures"
    echo "Use: .claude/scripts/analyze-validation.sh ${PR_NUM}"
    exit 1
  fi

  # Still pending, wait and check again
  if [[ $i -lt ${MAX_CHECKS} ]]; then
    echo "Waiting ${CHECK_INTERVAL}s before next check..."
    sleep "${CHECK_INTERVAL}"
  fi
done

echo "⏱️  Timeout: Reached maximum checks (${MAX_CHECKS})"
echo "Some checks still pending. Current status:"
gh pr checks "${PR_NUM}" --repo openshift/release | grep -E "$(IFS='|'; echo "${VALIDATION_CHECKS[*]}")"

exit 2
