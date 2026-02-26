#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# For rehearsal only
export PAYLOAD_TAG=4.22.0-0.nightly-2026-02-25-152806

echo "Starting claude-payload-analysis for payload: ${PAYLOAD_TAG}"

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
MAX_WAIT=28800  # 8 hours in seconds
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

# Write Claude settings file with permissions allowlist
SETTINGS_FILE=$(mktemp /tmp/claude-settings-XXXXXX.json)
cat > "${SETTINGS_FILE}" << 'SETTINGS_EOF'
{
  "permissions": {
    "allow": [
      "Bash(python3:*)", "Bash(gh:*)", "Bash(gcloud:*)", "Bash(curl:*)",
      "Bash(jq:*)", "Bash(grep:*)", "Bash(cat:*)", "Bash(ls:*)",
      "Bash(mkdir:*)", "Bash(cp:*)", "Bash(chmod:*)", "Bash(head:*)",
      "Bash(tail:*)", "Bash(wc:*)", "Bash(sort:*)", "Bash(cut:*)",
      "Bash(tr:*)", "Bash(sed:*)", "Bash(awk:*)",
      "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)",
      "WebFetch(*)", "WebSearch(*)",
      "Task(*)", "Skill(*)"
    ]
  }
}
SETTINGS_EOF

# Run Claude to analyze the payload
echo "Invoking Claude to analyze payload ${PAYLOAD_TAG}..."

WORKDIR=$(mktemp -d /tmp/claude-analysis-XXXXXX)
cd "${WORKDIR}"

claude --settings-file "${SETTINGS_FILE}" \
    --output-format text \
    -p "/ci:analyze-payload ${VERSION}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-output.log" || true

# Copy HTML report(s) to artifact directory
echo "Copying reports to artifact directory..."
find "${WORKDIR}" -name "payload-analysis-*.html" -exec cp {} "${ARTIFACT_DIR}/" \;

# Check if we produced a report
if ls "${ARTIFACT_DIR}"/payload-analysis-*.html 1>/dev/null 2>&1; then
    echo "Analysis complete. Report(s) saved to artifact directory."
else
    echo "Warning: No HTML report was generated."
    exit 1
fi
