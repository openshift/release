#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-payload-analysis for payload: ${PAYLOAD_TAG}"

# Load credentials with xtrace disabled to prevent leaking secrets in logs
PREV_OPTS=$(set +o); set +x
if [ -f "${GITHUB_TOKEN_FILE}" ]; then
    export GH_TOKEN=$(cat "${GITHUB_TOKEN_FILE}")
    echo "GitHub token configured for gh CLI."
else
    echo "Warning: GitHub token file not found at ${GITHUB_TOKEN_FILE}, gh operations may fail."
fi
if [ -f "${SLACK_WEBHOOK_URL}" ]; then
    SLACK_WEBHOOK=$(cat "${SLACK_WEBHOOK_URL}")
    echo "Slack webhook configured."
else
    SLACK_WEBHOOK=""
    echo "Slack webhook file not found at ${SLACK_WEBHOOK_URL}, skipping notifications."
fi
eval "${PREV_OPTS}"

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

# Run Claude payload-agent to analyze the payload, stage reverts, and bisect suspects
echo "Invoking Claude payload-agent for payload ${PAYLOAD_TAG}..."

WORKDIR=$(mktemp -d /tmp/claude-analysis-XXXXXX)
cd "${WORKDIR}"

# Install the must-gather plugin for analyzing must-gather archives
echo "Installing must-gather plugin..."
claude plugin install must-gather@ai-helpers
echo "must-gather plugin installed."

timeout 7200 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch WebSearch Agent Skill" \
    --output-format stream-json \
    --max-turns 200 \
    -p "/ci:payload-agent ${PAYLOAD_TAG}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-output.log" || true

# Copy HTML report(s) and data files to artifact directory
echo "Copying reports to artifact directory..."
find "${WORKDIR}" -name "payload-analysis-*.html" -exec cp {} "${ARTIFACT_DIR}/" \;
find "${WORKDIR}" -name "payload-analysis-*-autodl.json" -exec cp {} "${ARTIFACT_DIR}/" \;

# Determine Prow job URL for Slack links
if [ "${JOB_TYPE:-}" = "presubmit" ]; then
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
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

    # Check if bisect experiments were initiated
    BISECT_YAML=$(find "${WORKDIR}" -name "*-bisect.yaml" -print -quit)

    # Send initial Slack notification
    if [ -n "${SLACK_WEBHOOK}" ]; then
        if [ -n "${BISECT_YAML}" ]; then
            SLACK_TEXT=":claude_thinking: *Rejected Payload Analysis*

${SUMMARY:-No summary available.}

:hourglass_flowing_sand: Bisect experiments are running. Follow-up results will be posted when complete.

<${PROW_JOB_URL}|:point_right: View Full Analysis Report>"
        else
            SLACK_TEXT=":claude_thinking: *Rejected Payload Analysis*

${SUMMARY:-No summary available.}

<${PROW_JOB_URL}|:point_right: View Full Analysis Report>"
        fi

        jq -n --arg text "$SLACK_TEXT" '{text: $text}' | \
            curl -sf -X POST -H 'Content-type: application/json' -d @- \
            "${SLACK_WEBHOOK}" || echo "Warning: Failed to send Slack notification."
    fi

    # Bisect Phase 2: poll for bisect job completion and re-run payload-agent
    if [ -n "${BISECT_YAML}" ]; then
        echo ""
        echo "=== Bisect experiments detected. Polling for job completion ==="

        # Extract pr-payload-tests URLs from the YAML
        PAYLOAD_TEST_URLS=$(grep 'payload_test_url:' "${BISECT_YAML}" | awk '{print $2}' | tr -d '"')

        BISECT_MAX_WAIT=21600  # 6 hours
        BISECT_POLL_INTERVAL=900  # 15 minutes
        BISECT_ELAPSED=0

        while true; do
            ALL_DONE=true
            for URL in ${PAYLOAD_TEST_URLS}; do
                # Check if pr-payload-tests page shows AllJobsFinished
                if ! curl -sf "${URL}" 2>/dev/null | grep -q "AllJobsFinished"; then
                    ALL_DONE=false
                    break
                fi
            done

            if ${ALL_DONE}; then
                echo "All bisect payload jobs have finished."
                break
            fi

            BISECT_ELAPSED=$((BISECT_ELAPSED + BISECT_POLL_INTERVAL))
            if [[ ${BISECT_ELAPSED} -ge ${BISECT_MAX_WAIT} ]]; then
                echo "Bisect job polling timed out after $((BISECT_MAX_WAIT / 3600)) hours."
                break  # Continue anyway — Phase 2 will mark timed-out experiments as inconclusive
            fi

            echo "[Bisect poll | $((BISECT_ELAPSED / 60))m elapsed] Jobs still running..."
            sleep ${BISECT_POLL_INTERVAL}
        done

        # Re-run Claude to collect bisect results (Phase 2)
        echo "Re-running payload-agent for bisect Phase 2..."
        timeout 3600 claude \
            --model "${CLAUDE_MODEL}" \
            --allowedTools "Bash Read Write Edit Grep Glob WebFetch WebSearch Agent Skill" \
            --output-format stream-json \
            --max-turns 200 \
            -p "/ci:payload-agent ${PAYLOAD_TAG}" \
            --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-phase2-output.log" || true

        # Copy updated reports
        find "${WORKDIR}" -name "payload-analysis-*.html" -exec cp {} "${ARTIFACT_DIR}/" \;
        find "${WORKDIR}" -name "payload-analysis-*-autodl.json" -exec cp {} "${ARTIFACT_DIR}/" \;

        # Send follow-up Slack notification with bisect results
        PHASE2_SUMMARY=$(claude \
            --model "${CLAUDE_MODEL}" \
            --continue \
            --output-format text \
            --max-turns 1 \
            -p "Write a very brief summary of the bisect results suitable for a Slack message. Which PRs were confirmed as causes? Which were cleared? Include the payload tag. Plain text only, no markdown. 2-3 sentences max." \
            2>/dev/null) || PHASE2_SUMMARY=""

        if [ -n "${SLACK_WEBHOOK}" ]; then
            FOLLOWUP_TEXT=":robot_face::white_check_mark: *Bisect Results for ${PAYLOAD_TAG}*

${PHASE2_SUMMARY:-Bisect Phase 2 complete. Check the report for details.}

<${PROW_JOB_URL}|:point_right: View Updated Report>"

            jq -n --arg text "$FOLLOWUP_TEXT" '{text: $text}' | \
                curl -sf -X POST -H 'Content-type: application/json' -d @- \
                "${SLACK_WEBHOOK}" || echo "Warning: Failed to send bisect Slack notification."
        fi
    fi
else
    echo "Warning: No HTML report was generated."
    exit 1
fi
