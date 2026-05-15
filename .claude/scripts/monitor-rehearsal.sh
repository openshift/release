#!/bin/bash
# Monitor a /pj-rehearse job until completion or timeout
# Usage: monitor-rehearsal.sh <PR_NUMBER> <SHORT_JOB_NAME> [DURATION_HOURS] [CHECK_INTERVAL_SECONDS]
#
# Example: monitor-rehearsal.sh 79244 azure-ipi-coco 3 300
#
# This script is part of the /pj-rehearse-debug skill for monitoring long-running rehearsal jobs.

set -euo pipefail

# Parse arguments
PR_NUM="${1:?PR number required}"
JOB_NAME="${2:?Short job name required (e.g., 'azure-ipi-coco')}"
DURATION_HOURS="${3:-3}"
CHECK_INTERVAL="${4:-300}"

# Calculate end time
END_TIME=$(($(date +%s) + (DURATION_HOURS * 3600)))

echo "=== Rehearsal Monitor ==="
echo "PR: https://github.com/openshift/release/pull/${PR_NUM}"
echo "Job pattern: ${JOB_NAME}"
echo "Duration: ${DURATION_HOURS} hours (until $(date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S'))"
echo "Check interval: ${CHECK_INTERVAL} seconds"
echo ""

iteration=1
while true; do
    current_time=$(date +%s)

    # Check if duration elapsed
    if [ ${current_time} -ge ${END_TIME} ]; then
        echo ""
        echo "=== Monitoring Duration Completed ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        final_status=$(gh pr checks ${PR_NUM} --repo openshift/release 2>&1 | grep "${JOB_NAME}" || echo "Status unavailable")
        echo "Final Status: ${final_status}"
        echo ""
        echo "Monitoring ended. Check Prow URL for full details."
        exit 0
    fi

    # Check job status
    status_line=$(gh pr checks ${PR_NUM} --repo openshift/release 2>&1 | grep "${JOB_NAME}" || echo "")

    if [ -n "${status_line}" ]; then
        job_status=$(echo "${status_line}" | awk '{print $2}')
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        elapsed_mins=$(( (current_time - (END_TIME - (DURATION_HOURS * 3600))) / 60 ))

        echo "[${iteration}] ${timestamp} (${elapsed_mins}m) - Status: ${job_status}"

        # Check if job completed
        if echo "${job_status}" | grep -qE "^(pass|fail)$"; then
            echo ""
            echo "=== Job Completed ==="
            echo "Status: ${job_status}"
            echo ""
            echo "Full details:"
            echo "${status_line}"
            echo ""

            # Extract Prow URL
            prow_url=$(echo "${status_line}" | awk '{print $4}')
            echo "Prow Logs: ${prow_url}"
            echo ""

            if [ "${job_status}" = "pass" ]; then
                echo "✓ SUCCESS"
            else
                echo "✗ FAILURE - Check Prow logs for error details"
                echo ""
                echo "Quick analysis:"
                echo "  curl -sL \"${prow_url}/build-log.txt\" | tail -200"
            fi

            echo ""
            echo "Monitoring ended."
            exit 0
        fi
    else
        echo "[${iteration}] $(date '+%Y-%m-%d %H:%M:%S') - No status found (job may not have started yet)"
    fi

    iteration=$((iteration + 1))
    sleep ${CHECK_INTERVAL}
done
