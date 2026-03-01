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

while true; do
    RELEASE_JSON=$(curl -sf "${API_URL}")
    PENDING=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Pending")] | length')
    FAILED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Failed")] | length')
    TOTAL=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[]] | length')

    echo "Blocking jobs: ${TOTAL} total, ${PENDING} pending, ${FAILED} failed"

    if [[ "${PENDING}" -eq 0 ]]; then
        if [[ "${FAILED}" -eq 0 ]]; then
            echo "All blocking jobs succeeded. No analysis needed."
            exit 0
        fi
        echo "All blocking jobs have completed. ${FAILED} failed. Starting analysis..."
        break
    fi

    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
        echo "Timed out after ${MAX_WAIT}s waiting for blocking jobs to complete (${PENDING} still pending)."
        exit 1
    fi

    sleep ${POLL_INTERVAL}
done

# Run Claude to analyze the payload
echo "Invoking Claude to analyze payload ${PAYLOAD_TAG}..."

WORKDIR=$(mktemp -d /tmp/claude-analysis-XXXXXX)
cd "${WORKDIR}"

# Install the must-gather plugin for analyzing must-gather archives
echo "Installing must-gather plugin..."
claude plugin install must-gather@ai-helpers
echo "must-gather plugin installed."

timeout 7200 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill" \
    --output-format stream-json \
    --max-turns 100 \
    -p "/ci:analyze-payload ${PAYLOAD_TAG}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-output.log" || true

# Copy HTML report(s) to artifact directory
echo "Copying reports to artifact directory..."
find "${WORKDIR}" -name "payload-analysis-*.html" -exec cp {} "${ARTIFACT_DIR}/" \;

# Analyze cost from claude stream-json output
echo "=== Cost Analysis ==="
CLAUDE_LOG="${ARTIFACT_DIR}/claude-output.log"
if [ -f "${CLAUDE_LOG}" ]; then
    # Extract token usage from the result message in stream-json output
    # The final result message contains cumulative usage stats
    # Use python to parse the result line since it may contain control chars that break jq
    COST_JSON=$(grep '"type":"result"' "${CLAUDE_LOG}" | tail -1 | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    cost = d.get('total_cost_usd', 0)
    usage = d.get('modelUsage', {})
    print(f'Total cost: \${cost:.4f}')
    for model, u in usage.items():
        print(f'  {model}: input={u[\"inputTokens\"]} output={u[\"outputTokens\"]} cache_read={u[\"cacheReadInputTokens\"]} cache_create={u[\"cacheCreationInputTokens\"]} cost=\${u[\"costUSD\"]:.4f}')
    summary = {'payload': '${PAYLOAD_TAG}', 'total_cost_usd': cost, 'modelUsage': usage}
    with open('${ARTIFACT_DIR}/cost-summary.json', 'w') as f:
        json.dump(summary, f, indent=2)
except Exception as e:
    print(f'Failed to parse cost data: {e}')
" 2>&1 || true)
    echo "${COST_JSON}"
    if [ -f "${ARTIFACT_DIR}/cost-summary.json" ]; then
        echo "Cost summary written to ${ARTIFACT_DIR}/cost-summary.json"
    fi
else
    echo "No claude output log found, skipping cost analysis."
fi

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
