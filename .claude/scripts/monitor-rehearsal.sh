#!/bin/bash
# Monitor a /pj-rehearse job until completion or timeout
# Usage: monitor-rehearsal.sh <PR_NUMBER> <SHORT_JOB_NAME> [DURATION_HOURS] [CHECK_INTERVAL] [STEP_NAME] [ARTIFACT_WAIT]
#
# Examples:
#   # Monitor full job completion (default)
#   monitor-rehearsal.sh 79244 azure-ipi-coco
#
#   # Monitor until specific step succeeds
#   monitor-rehearsal.sh 79244 azure-ipi-coco 3 300 "install-trustee-operator"
#
#   # Monitor step with custom artifact wait time
#   monitor-rehearsal.sh 79244 azure-ipi-coco 3 300 "install-trustee-operator" 120
#
# This script is part of the /pj-rehearse-debug skill for monitoring long-running rehearsal jobs.

set -euo pipefail

# Parse arguments
PR_NUM="${1:?PR number required}"
JOB_NAME="${2:?Short job name required (e.g., 'azure-ipi-coco')}"
DURATION_HOURS="${3:-3}"
CHECK_INTERVAL="${4:-300}"
STEP_NAME="${5:-}"           # Optional: monitor specific step
ARTIFACT_WAIT="${6:-60}"     # Wait time after step success for artifacts (seconds)

# Calculate end time
END_TIME=$(($(date +%s) + (DURATION_HOURS * 3600)))

echo "=== Rehearsal Monitor ==="
echo "PR: https://github.com/openshift/release/pull/${PR_NUM}"
echo "Job pattern: ${JOB_NAME}"
if [ -n "${STEP_NAME}" ]; then
    echo "Monitoring step: ${STEP_NAME} (will exit after step succeeds + ${ARTIFACT_WAIT}s artifact wait)"
else
    echo "Monitoring: Full job completion"
fi
echo "Duration: ${DURATION_HOURS} hours (until $(date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S'))"
echo "Check interval: ${CHECK_INTERVAL} seconds"
echo ""

PROW_URL=""
STEP_SUCCEEDED=false

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

        # Extract Prow URL if not already set
        if [ -z "${PROW_URL}" ] && [ "${job_status}" != "pending" ]; then
            PROW_URL=$(echo "${status_line}" | awk '{print $4}')
        fi

        # If monitoring a specific step, check build log
        if [ -n "${STEP_NAME}" ] && [ -n "${PROW_URL}" ] && [ "${STEP_SUCCEEDED}" = false ]; then
            # Check if step has succeeded in build log
            if curl -sS "${PROW_URL}/build-log.txt" 2>/dev/null | grep -q "Step.*${STEP_NAME} succeeded after"; then
                STEP_SUCCEEDED=true
                echo ""
                echo "[${iteration}] ${timestamp} (${elapsed_mins}m) - Step '${STEP_NAME}' SUCCEEDED"
                echo "Waiting ${ARTIFACT_WAIT}s for artifacts to be collected..."
                sleep ${ARTIFACT_WAIT}
                echo ""
                echo "=== Step Monitoring Complete ==="
                echo "Step: ${STEP_NAME}"
                echo "Status: SUCCESS"
                echo "Prow Logs: ${PROW_URL}"
                echo ""
                echo "Note: Full job is still running. Check Prow URL for complete results."
                echo "Monitoring ended."
                exit 0
            fi
        fi

        echo "[${iteration}] ${timestamp} (${elapsed_mins}m) - Status: ${job_status}"

        # Check if job completed (default behavior or if step monitoring not requested)
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
