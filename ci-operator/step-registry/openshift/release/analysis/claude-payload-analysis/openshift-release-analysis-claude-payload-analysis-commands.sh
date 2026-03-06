#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-payload-analysis for payload: ${PAYLOAD_TAG}"

# Install gcloud CLI for GCS artifact access (no root required)
echo "Installing gcloud CLI..."
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
/tmp/google-cloud-sdk/install.sh --quiet --path-update true
export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
echo "gcloud CLI installed."

# Parse version and stream from payload tag
# Format: 4.22.0-0.nightly-2026-02-25-152806
VERSION=$(echo "${PAYLOAD_TAG}" | grep -oP '^\d+\.\d+')
STREAM=$(echo "${PAYLOAD_TAG}" | grep -oP '\d+\.\d+\.\d+-\d+\.\K[a-z]+')

RELEASE_CONTROLLER_URL="https://amd64.ocp.releases.ci.openshift.org"
STREAM_NAME="${VERSION}.0-0.${STREAM}"
API_URL="${RELEASE_CONTROLLER_URL}/api/v1/releasestream/${STREAM_NAME}/release/${PAYLOAD_TAG}"

echo "Version: ${VERSION}, Stream: ${STREAM}"
echo "Release API: ${API_URL}"

# Poll until all blocking jobs have finished (no Pending jobs remain).
# We can't wait for the payload to reach terminal state because this
# analysis job is itself part of the payload's verification jobs.
MAX_WAIT=36000 # 10 hours in seconds
POLL_INTERVAL=300  # 5 minutes
ELAPSED=0
POLL_COUNT=0

PHASE_WAIT_START=$(date +%s)

echo ""
echo "=== Waiting for all blocking jobs to complete before analysis ==="
echo "Polling every $((POLL_INTERVAL / 60)) minutes (timeout: $((MAX_WAIT / 3600)) hours)"
echo ""

while true; do
    POLL_COUNT=$((POLL_COUNT + 1))
    RELEASE_JSON=$(curl -sf "${API_URL}")
    PENDING=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Pending")] | length')
    FAILED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Failed")] | length')
    SUCCEEDED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Succeeded")] | length')
    TOTAL=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[]] | length')

    ELAPSED_MIN=$((ELAPSED / 60))
    echo "[Poll #${POLL_COUNT} | ${ELAPSED_MIN}m elapsed] Blocking jobs: ${SUCCEEDED}/${TOTAL} succeeded, ${PENDING} pending, ${FAILED} failed"

    if [[ "${PENDING}" -eq 0 ]]; then
        echo ""
        if [[ "${FAILED}" -eq 0 ]]; then
            echo "All ${TOTAL} blocking jobs succeeded. No analysis needed."
            exit 0
        fi
        echo "All blocking jobs have completed. ${FAILED}/${TOTAL} failed. Starting analysis..."
        break
    fi

    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
        echo ""
        echo "Timed out after $((MAX_WAIT / 3600)) hours waiting for blocking jobs to complete (${PENDING} still pending)."
        exit 1
    fi

    echo "  Next check in $((POLL_INTERVAL / 60)) minutes..."
    sleep ${POLL_INTERVAL}
done

PHASE_WAIT_DURATION=$(( $(date +%s) - PHASE_WAIT_START ))

# Run Claude to analyze the payload
echo "Invoking Claude to analyze payload ${PAYLOAD_TAG}..."

WORKDIR=$(mktemp -d /tmp/claude-analysis-XXXXXX)
cd "${WORKDIR}"

# Install the must-gather plugin for analyzing must-gather archives
echo "Installing must-gather plugin..."
claude plugin install must-gather@ai-helpers
echo "must-gather plugin installed."

PHASE_ANALYSIS_START=$(date +%s)
CLAUDE_EXIT=0
timeout 7200 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill" \
    --output-format stream-json \
    --max-turns 100 \
    -p "/ci:analyze-payload ${PAYLOAD_TAG}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-output.log" || CLAUDE_EXIT=$?

PHASE_ANALYSIS_DURATION=$(( $(date +%s) - PHASE_ANALYSIS_START ))

# If Claude timed out (exit 124), nudge it to wrap up with a shorter timeout
PHASE_NUDGE_START=$(date +%s)
NUDGE_EXIT=0
if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo ""
    echo "Claude timed out after 2 hours. Nudging to wrap up..."
    timeout 900 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill" \
        --output-format stream-json \
        --max-turns 20 \
        -p "I think you got stuck and hit the timeout. Please wrap up your analysis now with whatever data you have collected so far. Generate the required report artifacts immediately. Note you timed out in the report." \
        --verbose 2>&1 | tee -a "${ARTIFACT_DIR}/claude-output.log" || NUDGE_EXIT=$?
fi
PHASE_NUDGE_DURATION=$(( $(date +%s) - PHASE_NUDGE_START ))

# Copy HTML report(s) to artifact directory before anything else that might fail
echo "Copying reports to artifact directory..."
find "${WORKDIR}" -name "payload-analysis-*.html" -exec cp {} "${ARTIFACT_DIR}/" \;
find "${WORKDIR}" -name "*-autodl.json" -exec cp {} "${ARTIFACT_DIR}/" \;

# Generate JUnit XML for timeout and phase duration tracking
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-ci.xml"
PHASE_PREFIX="[sig-claude]"
TIMEOUT_TESTCASE="${PHASE_PREFIX} Claude should complete in a reasonable time"
TOTAL_DURATION=$(( PHASE_WAIT_DURATION + PHASE_ANALYSIS_DURATION + PHASE_NUDGE_DURATION ))

PHASE_CASES="  <testcase name=\"${PHASE_PREFIX} Phase: wait for blocking jobs\" time=\"${PHASE_WAIT_DURATION}\"/>
  <testcase name=\"${PHASE_PREFIX} Phase: analysis\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"

TIMEOUT_CASES=""
FAILURE_COUNT=0
TIMEOUT_TEST_COUNT=0

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    TIMEOUT_TEST_COUNT=1
    FAILURE_COUNT=1
    TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\">
    <failure message=\"Claude timed out after 2 hours\">Claude exceeded the 2 hour time limit and had to be nudged to wrap up.</failure>
  </testcase>"

    HAS_REPORT=false
    find "${WORKDIR}" -name "payload-analysis-*.html" -quit | grep -q . && HAS_REPORT=true

    PHASE_CASES="${PHASE_CASES}
  <testcase name=\"${PHASE_PREFIX} Phase: recovery nudge\" time=\"${PHASE_NUDGE_DURATION}\"/>"

    if [[ "${NUDGE_EXIT}" -eq 0 ]] && [[ "${HAS_REPORT}" == "true" ]]; then
        # Flake: timed out but recovered after nudge
        TIMEOUT_TEST_COUNT=2
        TIMEOUT_CASES="${TIMEOUT_CASES}
  <testcase name=\"${TIMEOUT_TESTCASE} (recovery)\" time=\"${PHASE_NUDGE_DURATION}\"/>"
    else
        # Hard failure: nudge also failed
        TIMEOUT_TEST_COUNT=2
        FAILURE_COUNT=2
        TIMEOUT_CASES="${TIMEOUT_CASES}
  <testcase name=\"${TIMEOUT_TESTCASE} (recovery)\" time=\"${PHASE_NUDGE_DURATION}\">
    <failure message=\"Claude failed to recover after nudge\">Claude was nudged to wrap up but did not produce a report (exit code: ${NUDGE_EXIT}).</failure>
  </testcase>"
    fi
else
    TIMEOUT_TEST_COUNT=1
    TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"
fi

TEST_COUNT=$(( 2 + TIMEOUT_TEST_COUNT ))
cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-ci" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${PHASE_CASES}
${TIMEOUT_CASES}
</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"

# Check if we produced a report
if ls "${ARTIFACT_DIR}"/payload-analysis-*.html 1>/dev/null 2>&1; then
    echo "Analysis complete. Report(s) saved to artifact directory."

    # Ask Claude to summarize its findings for Slack
    echo "Asking Claude to summarize findings for Slack..."
    SUMMARY=$(claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --output-format text \
        --max-turns 1 \
        -p "Write a very brief summary of your findings suitable for a Slack message. Include the payload tag and list the failed jobs. Include a brief, encouraging CI-related joke or pun. Plain text only, no markdown. 2-3 sentences max." \
        2>/dev/null) || SUMMARY=""

    # Send Slack notification
    if [ "${JOB_TYPE:-}" = "presubmit" ]; then
        PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
    else
        PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
    fi
    if [ -f "${SLACK_WEBHOOK_URL}" ]; then
        WEBHOOK=$(cat "${SLACK_WEBHOOK_URL}")

        SLACK_TEXT=":this_is_fine::alert-siren: *Rejected Payload Analysis* :alert-siren::this_is_fine:

:robot_face: ${SUMMARY:-No summary available.}

<${PROW_JOB_URL}|:point_right: View Full Analysis Report>"

        jq -n --arg text "$SLACK_TEXT" '{text: $text}' | \
            curl -sf -X POST -H 'Content-type: application/json' -d @- \
            "${WEBHOOK}" || echo "Warning: Failed to send Slack notification."
    else
        echo "Slack webhook file not found at ${SLACK_WEBHOOK_URL}, skipping notification."
    fi
else
    echo "Warning: No HTML report was generated."
    exit 1
fi
