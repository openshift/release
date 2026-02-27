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
    INPUT_TOKENS=$(grep '"type":"result"' "${CLAUDE_LOG}" | tail -1 | jq -r '.total_input_tokens // 0' 2>/dev/null || echo "0")
    OUTPUT_TOKENS=$(grep '"type":"result"' "${CLAUDE_LOG}" | tail -1 | jq -r '.total_output_tokens // 0' 2>/dev/null || echo "0")
    CACHE_READ=$(grep '"type":"result"' "${CLAUDE_LOG}" | tail -1 | jq -r '.total_cache_read_input_tokens // 0' 2>/dev/null || echo "0")
    CACHE_CREATE=$(grep '"type":"result"' "${CLAUDE_LOG}" | tail -1 | jq -r '.total_cache_creation_input_tokens // 0' 2>/dev/null || echo "0")
    MODEL_USED=$(grep '"type":"result"' "${CLAUDE_LOG}" | tail -1 | jq -r '.model // "unknown"' 2>/dev/null || echo "unknown")

    # Claude Opus 4.6 pricing per million tokens:
    #   input=$5, output=$25, cache_read=$0.50, cache_create=$6.25
    COST=$(awk "BEGIN {printf \"%.4f\", ($INPUT_TOKENS * 5 + $OUTPUT_TOKENS * 25 + $CACHE_READ * 0.5 + $CACHE_CREATE * 6.25) / 1000000}" 2>/dev/null || echo "0.0000")

    # Format numbers with comma separators
    format_number() {
        printf "%s" "$1" | sed -e ':a' -e 's/\([0-9]\)\([0-9]\{3\}\)\(\b\)/\1,\2\3/' -e 'ta'
    }

    echo "Model: ${MODEL_USED}"
    echo "Input tokens:        $(format_number "${INPUT_TOKENS}")"
    echo "Output tokens:       $(format_number "${OUTPUT_TOKENS}")"
    echo "Cache read tokens:   $(format_number "${CACHE_READ}")"
    echo "Cache create tokens: $(format_number "${CACHE_CREATE}")"
    echo "Estimated cost:      \$${COST}"

    # Write cost summary as a JSON artifact
    cat > "${ARTIFACT_DIR}/cost-summary.json" <<COSTEOF
{
  "payload": "${PAYLOAD_TAG}",
  "model": "${MODEL_USED}",
  "input_tokens": ${INPUT_TOKENS},
  "output_tokens": ${OUTPUT_TOKENS},
  "cache_read_input_tokens": ${CACHE_READ},
  "cache_creation_input_tokens": ${CACHE_CREATE},
  "estimated_cost_usd": ${COST}
}
COSTEOF
    echo "Cost summary written to ${ARTIFACT_DIR}/cost-summary.json"
else
    echo "No claude output log found, skipping cost analysis."
fi

# Check if we produced a report
if ls "${ARTIFACT_DIR}"/payload-analysis-*.html 1>/dev/null 2>&1; then
    echo "Analysis complete. Report(s) saved to artifact directory."
else
    echo "Warning: No HTML report was generated."
    exit 1
fi
