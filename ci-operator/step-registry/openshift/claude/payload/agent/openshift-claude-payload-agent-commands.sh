#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-payload-agent for payload: ${PAYLOAD_TAG}"
echo "Model: ${CLAUDE_MODEL}"

# Load secrets with xtrace disabled to prevent leaking credentials in logs
set +x
if [ -f "${GITHUB_TOKEN_PATH}" ]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
    echo "GitHub token loaded."
else
    echo "Warning: GitHub token not found at ${GITHUB_TOKEN_PATH}. Revert operations will not be available."
fi

if [[ "${ENABLE_SLACK_NOTIFICATIONS}" == "true" ]] && [ -f "${SLACK_WEBHOOK_URL}" ]; then
    SLACK_WEBHOOK=$(cat "${SLACK_WEBHOOK_URL}")
    echo "Slack webhook loaded."
elif [[ "${ENABLE_SLACK_NOTIFICATIONS}" != "true" ]]; then
    SLACK_WEBHOOK=""
    echo "Slack notifications disabled via ENABLE_SLACK_NOTIFICATIONS."
else
    SLACK_WEBHOOK=""
    echo "Warning: Slack webhook not found at ${SLACK_WEBHOOK_URL}. Notifications will be skipped."
fi

JIRA_API_TOKEN=""
if [ -f "${JIRA_API_TOKEN_PATH}" ]; then
    JIRA_API_TOKEN=$(cat "${JIRA_API_TOKEN_PATH}")
    echo "Jira API token loaded."
else
    echo "Warning: Jira API token not found at ${JIRA_API_TOKEN_PATH}. Jira operations will not be available."
fi

JIRA_USERNAME=""
if [ -f "${JIRA_USERNAME_PATH}" ]; then
    JIRA_USERNAME=$(cat "${JIRA_USERNAME_PATH}")
    echo "Jira username loaded."
else
    echo "Warning: Jira username not found at ${JIRA_USERNAME_PATH}. Jira operations will not be available."
fi

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
PAYLOAD_URL="${RELEASE_CONTROLLER_URL}/releasestream/${STREAM_NAME}/release/${PAYLOAD_TAG}"

echo "Version: ${VERSION}, Stream: ${STREAM}"
echo "Release API: ${API_URL}"
echo "Automatic reverts enabled: ${ENABLE_PAYLOAD_REVERT}"

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
    # Guard against release controller race: jobs may briefly report as Succeeded before being dispatched
    NOT_STARTED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.url == null or .value.url == "")] | length')

    ELAPSED_MIN=$((ELAPSED / 60))
    echo "[Poll #${POLL_COUNT} | ${ELAPSED_MIN}m elapsed] Blocking jobs: ${SUCCEEDED}/${TOTAL} succeeded, ${PENDING} pending, ${FAILED} failed"

    if [[ "${NOT_STARTED}" -gt 0 ]]; then
        echo "  ${NOT_STARTED} job(s) have no prow URL yet, waiting for them to be dispatched..."
    elif [[ "${PENDING}" -eq 0 ]]; then
        echo ""
        if [[ "${FAILED}" -eq 0 ]]; then
            echo "All ${TOTAL} blocking jobs succeeded. No analysis needed."

            RETRIED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.retries > 0)] | length')
            TOTAL_RETRIES=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.retries > 0) | .value.retries] | add // 0')

            # Send Slack notification for accepted payload
            if [[ -n "${SLACK_WEBHOOK}" ]]; then
                RETRY_INFO=""
                if [[ "${RETRIED}" -gt 0 ]]; then
                    RETRY_INFO=" ${RETRIED} job(s) needed ${TOTAL_RETRIES} total retries."
                fi

                SLACK_TEXT=":green-check: *Payload Accepted for <${PAYLOAD_URL}|${PAYLOAD_TAG}>*

All ${TOTAL} blocking jobs succeeded.${RETRY_INFO}
_Agent: ${CLAUDE_MODEL}_"

                set +x
                jq -n --arg text "$SLACK_TEXT" '{text: $text}' | \
                    curl -sf -X POST -H 'Content-type: application/json' -d @- \
                    "${SLACK_WEBHOOK}" || echo "Warning: Failed to send Slack notification."
            fi

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

# Workaround: --continue + -p is broken (anthropics/claude-code#42376).
# Sessions created by -p get sessionKind tagged and are filtered from --continue lookup.
# Setting CLAUDE_CODE_ENTRYPOINT=-sdk-cli prevents the sessionKind tag from being set.
export CLAUDE_CODE_ENTRYPOINT=sdk-cli

# Run Claude to analyze the payload
echo "Invoking Claude to analyze payload ${PAYLOAD_TAG}..."

WORKDIR=$(mktemp -d /tmp/claude-analysis-XXXXXX)
cd "${WORKDIR}"

# Ensure reports and session logs are copied to artifacts even if the script exits early
copy_reports() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying reports to artifact directory..."
        find "${WORKDIR}" -name "payload-analysis-*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -name "*-autodl.json" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        find "${WORKDIR}" -name "payload-results-*.yaml" -exec cp {} "${ARTIFACT_DIR}/" \; || true
    fi

    # Archive the full Claude session directory (including subagent logs) for session continuation.
    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}
trap copy_reports EXIT TERM INT

# Install the must-gather plugin for analyzing must-gather archives
echo "Installing must-gather plugin..."
claude plugin install must-gather@ai-helpers
echo "must-gather plugin installed."

ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

SYSTEM_PROMPT="You are a diligent senior OpenShift release engineer triaging failures.

**CRITICAL**: You have many ci, must-gather, and jira skills at your disposal. You MUST load the relevant skills using the Skill tool BEFORE you begin any work. Do NOT improvise or guess. This applies equally to subagents: instruct every subagent to review its available skills and load the appropriate ones before beginning its investigation. A subagent that does not load a skill will produce shallow, unreliable analysis."

PHASE_ANALYSIS_START=$(date +%s)
CLAUDE_EXIT=0
timeout 3600 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    --append-system-prompt "${SYSTEM_PROMPT}" \
    -p "/ci:analyze-payload ${PAYLOAD_TAG}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-output.log" || CLAUDE_EXIT=$?

PHASE_ANALYSIS_DURATION=$(( $(date +%s) - PHASE_ANALYSIS_START ))

# If Claude timed out (exit 124), nudge it to wrap up with a shorter timeout
PHASE_NUDGE_START=$(date +%s)
NUDGE_EXIT=0
if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo ""
    echo "Claude timed out. Nudging to wrap up..."
    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 20 \
        -p "I think you got stuck and hit the timeout. Please wrap up your analysis now with whatever data you have collected so far. Generate the required report artifacts immediately. Note you timed out in the report." \
        --verbose 2>&1 | tee -a "${ARTIFACT_DIR}/claude-output.log" || NUDGE_EXIT=$?
fi
PHASE_NUDGE_DURATION=$(( $(date +%s) - PHASE_NUDGE_START ))

# Optionally stage reverts for high-confidence candidates
PHASE_REVERT_START=$(date +%s)
REVERT_EXIT=0
if [[ "${ENABLE_PAYLOAD_REVERT}" == "true" ]]; then
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        echo "Warning: Automatic reverts enabled but no GitHub token is available. Skipping reverts."
    elif ls "${WORKDIR}"/payload-results-*.yaml 1>/dev/null 2>&1; then
        echo ""
        echo "=== Staging reverts for high-confidence candidates ==="

        # Configure Jira MCP server for creating TRT issues
        REVERT_ALLOWED_TOOLS="${ALLOWED_TOOLS}"
        if [[ -n "${JIRA_API_TOKEN}" ]] && [[ -n "${JIRA_USERNAME}" ]]; then
            echo "Configuring Jira MCP server..."
            set +x
            claude mcp add \
                -e JIRA_URL="${JIRA_URL}" \
                -e JIRA_API_TOKEN="${JIRA_API_TOKEN}" \
                -e JIRA_USERNAME="${JIRA_USERNAME}" \
                --transport stdio \
                jira -- uvx mcp-atlassian@0.21.0
            echo "Jira MCP server configured."
            REVERT_ALLOWED_TOOLS="${REVERT_ALLOWED_TOOLS} mcp__jira__*"
        else
            echo "Warning: Jira API token or username not available. TRT issues will not be created."
        fi

        timeout 3600 claude \
            --model "${CLAUDE_MODEL}" \
            --continue \
            --allowedTools "${REVERT_ALLOWED_TOOLS}" \
            --output-format stream-json \
            --max-turns 50 \
            -p "/ci:payload-revert ${PAYLOAD_TAG}" \
            --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-revert.log" || REVERT_EXIT=$?

    else
        echo "Warning: No payload results YAML found. Skipping reverts."
    fi
else
    echo "Automatic reverts not enabled. Skipping revert stage."
fi
PHASE_REVERT_DURATION=$(( $(date +%s) - PHASE_REVERT_START ))

# Generate JUnit XML for timeout and phase duration tracking
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-ci.xml"
PHASE_PREFIX="[sig-claude]"
TIMEOUT_TESTCASE="${PHASE_PREFIX} Claude should complete in a reasonable time"
TOTAL_DURATION=$(( PHASE_WAIT_DURATION + PHASE_ANALYSIS_DURATION + PHASE_NUDGE_DURATION + PHASE_REVERT_DURATION ))

PHASE_CASES="  <testcase name=\"${PHASE_PREFIX} Phase: wait for blocking jobs\" time=\"${PHASE_WAIT_DURATION}\"/>
  <testcase name=\"${PHASE_PREFIX} Phase: analysis\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"

TIMEOUT_CASES=""
FAILURE_COUNT=0

if [[ "${ENABLE_PAYLOAD_REVERT}" == "true" ]]; then
    if [[ "${REVERT_EXIT}" -ne 0 ]]; then
        FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
        PHASE_CASES="${PHASE_CASES}
  <testcase name=\"${PHASE_PREFIX} Phase: payload revert\" time=\"${PHASE_REVERT_DURATION}\">
    <failure message=\"Payload revert failed with exit code ${REVERT_EXIT}\">Claude payload revert exited with code ${REVERT_EXIT}.</failure>
  </testcase>"
    else
        PHASE_CASES="${PHASE_CASES}
  <testcase name=\"${PHASE_PREFIX} Phase: payload revert\" time=\"${PHASE_REVERT_DURATION}\"/>"
    fi
fi
TIMEOUT_TEST_COUNT=0

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    TIMEOUT_TEST_COUNT=1
    FAILURE_COUNT=1
    TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
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

PHASE_COUNT=2
if [[ "${ENABLE_PAYLOAD_REVERT}" == "true" ]]; then
    PHASE_COUNT=3
fi
TEST_COUNT=$(( PHASE_COUNT + TIMEOUT_TEST_COUNT ))
cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-ci" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${PHASE_CASES}
${TIMEOUT_CASES}
</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"

# Check if we produced a report
if ls "${WORKDIR}"/payload-analysis-*.html 1>/dev/null 2>&1; then
    echo "Analysis complete."
else
    echo "Warning: No HTML report was generated."
    exit 1
fi

# Send Slack summary including analysis and any revert actions
if [ "${JOB_TYPE:-}" = "presubmit" ]; then
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
fi

echo "Asking Claude to summarize findings for Slack..."
SUMMARY=$(claude \
    --model "${CLAUDE_MODEL}" \
    --continue \
    --output-format text \
    --max-turns 5 \
    -p "Write a very brief summary of your findings suitable for a Slack message. Include the payload tag and list the failed jobs. If any revert PRs were opened, include their URLs as links for Slack. Include a brief, encouraging CI-related joke or pun. Plain text only, no markdown. 2-3 sentences max." \
    2>/dev/null) || SUMMARY=""

if [[ -n "${SLACK_WEBHOOK}" ]]; then
    SLACK_TEXT=":claude-thinking: *Payload Analysis for <${PAYLOAD_URL}|${PAYLOAD_TAG}>*

${SUMMARY:-No summary available.}

<${PROW_JOB_URL}|:point_right: View Full Analysis Report>
_Agent: ${CLAUDE_MODEL}_"

    set +x
    jq -n --arg text "$SLACK_TEXT" '{text: $text}' | \
        curl -sf -X POST -H 'Content-type: application/json' -d @- \
        "${SLACK_WEBHOOK}" || echo "Warning: Failed to send Slack notification."
fi
