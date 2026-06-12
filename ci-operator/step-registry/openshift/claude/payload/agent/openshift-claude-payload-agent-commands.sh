#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# --- Gangway override ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_TAG:-}" ]]; then
    echo "Applying Gangway override: PAYLOAD_TAG=${MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_TAG}"
    PAYLOAD_TAG="${MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_TAG}"
fi

if [[ -z "${PAYLOAD_TAG:-}" ]]; then
    echo "ERROR: PAYLOAD_TAG is not set. This job must be triggered via Gangway with MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_TAG."
    exit 1
fi

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

# Poll until blocking jobs finish OR the payload reaches a terminal state.
# The release controller can report jobs as Pending even after they complete
# in Prow, so also check the payload phase as a fallback. The phase can be
# briefly wrong at creation time (RC bug), so we require PHASE_GRACE_PERIOD
# to elapse before trusting a terminal phase.
MAX_WAIT=36000 # 10 hours in seconds
POLL_INTERVAL=300  # 5 minutes
PHASE_GRACE_PERIOD=3600 # 1 hour
ELAPSED=0
POLL_COUNT=0

# Extract payload creation time from the tag (e.g. 4.22.0-0.nightly-2026-02-25-152806)
PAYLOAD_TIMESTAMP=$(echo "${PAYLOAD_TAG}" | grep -oP '\d{4}-\d{2}-\d{2}-\d{6}$')
PAYLOAD_CREATED=$(date -u -d "${PAYLOAD_TIMESTAMP:0:10} ${PAYLOAD_TIMESTAMP:11:2}:${PAYLOAD_TIMESTAMP:13:2}:${PAYLOAD_TIMESTAMP:15:2}" +%s 2>/dev/null || echo "0")

PHASE_WAIT_START=$(date +%s)

echo ""
echo "=== Waiting for blocking jobs to complete (or payload to reach terminal state) ==="
echo "Polling every $((POLL_INTERVAL / 60)) minutes (timeout: $((MAX_WAIT / 3600)) hours)"
if [[ "${PAYLOAD_CREATED}" -gt 0 ]]; then
    echo "Payload created at: $(date -u -d "@${PAYLOAD_CREATED}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "${PAYLOAD_TIMESTAMP}")"
    echo "Terminal phase trusted after: $((PHASE_GRACE_PERIOD / 60)) minutes from creation"
fi
echo ""

while true; do
    POLL_COUNT=$((POLL_COUNT + 1))
    RELEASE_JSON=$(curl -sf "${API_URL}" || true)
    if [[ -z "${RELEASE_JSON}" ]]; then
        echo "  Warning: Failed to fetch release API. Retrying next poll..."
        sleep ${POLL_INTERVAL}
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        continue
    fi
    PENDING=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Pending")] | length')
    FAILED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Failed")] | length')
    SUCCEEDED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.state == "Succeeded")] | length')
    TOTAL=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[]] | length')
    PHASE=$(echo "${RELEASE_JSON}" | jq -r '.phase // "Unknown"')
    # Guard against release controller race: jobs may briefly report as Succeeded before being dispatched
    NOT_STARTED=$(echo "${RELEASE_JSON}" | jq '[.results.blockingJobs // {} | to_entries[] | select(.value.url == null or .value.url == "")] | length')

    ELAPSED_MIN=$((ELAPSED / 60))
    echo "[Poll #${POLL_COUNT} | ${ELAPSED_MIN}m elapsed] Phase: ${PHASE} | Blocking jobs: ${SUCCEEDED}/${TOTAL} succeeded, ${PENDING} pending, ${FAILED} failed"

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
_Model: ${CLAUDE_MODEL}_"

                set +x
                jq -n --arg text "$SLACK_TEXT" '{text: $text}' | \
                    curl -sf -X POST -H 'Content-type: application/json' -d @- \
                    "${SLACK_WEBHOOK}" || echo "Warning: Failed to send Slack notification."
            fi

            exit 0
        fi
        echo "All blocking jobs have completed. ${FAILED}/${TOTAL} failed. Starting analysis..."
        break
    elif [[ "${PHASE}" == "Accepted" || "${PHASE}" == "Rejected" ]]; then
        NOW=$(date +%s)
        PAYLOAD_AGE=$(( NOW - PAYLOAD_CREATED ))
        if [[ "${PAYLOAD_CREATED}" -gt 0 && "${PAYLOAD_AGE}" -lt "${PHASE_GRACE_PERIOD}" ]]; then
            REMAINING=$(( (PHASE_GRACE_PERIOD - PAYLOAD_AGE) / 60 ))
            echo "  Payload phase is ${PHASE} but payload is only $((PAYLOAD_AGE / 60))m old (grace period: $((PHASE_GRACE_PERIOD / 60))m). Waiting ${REMAINING}m more before trusting phase..."
        else
            echo ""
            echo "Payload reached terminal state (${PHASE}) with ${PENDING} job(s) still pending."
            if [[ "${FAILED}" -gt 0 ]]; then
                echo "${FAILED}/${TOTAL} blocking jobs failed. Starting analysis..."
                break
            elif [[ "${PHASE}" == "Accepted" ]]; then
                echo "Payload was accepted. No analysis needed."
                exit 0
            fi
        fi
    fi

    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
        echo ""
        echo "ERROR: Timed out after $((MAX_WAIT / 3600)) hours waiting for blocking jobs to complete (${PENDING} still pending). Proceeding to analyze what we have..."
        break
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

# Create payload snapshot deterministically (no tokens spent)
echo ""
echo "=== Creating payload snapshot ==="
SNAPSHOT_SCRIPT="/opt/ai-helpers/plugins/ci/skills/payload-snapshot/scripts/payload_snapshot.py"
SNAPSHOT_DIR="${WORKDIR}/snapshot"
PHASE_SNAPSHOT_START=$(date +%s)
python3 "${SNAPSHOT_SCRIPT}" "${PAYLOAD_TAG}" --output-dir "${SNAPSHOT_DIR}"
PHASE_SNAPSHOT_DURATION=$(( $(date +%s) - PHASE_SNAPSHOT_START ))
echo "Snapshot created in ${PHASE_SNAPSHOT_DURATION}s"
echo "Archiving payload snapshot to artifacts..."
tar -czf "${ARTIFACT_DIR}/snapshot-${PAYLOAD_TAG}.tar.gz" -C "${SNAPSHOT_DIR}" .

SNAPSHOT_DATA_DIR=$(dirname "$(find "${SNAPSHOT_DIR}" -name summary.json -print -quit)")
echo "Snapshot data dir: ${SNAPSHOT_DATA_DIR}"

# Install the must-gather plugin for analyzing must-gather archives
echo "Installing must-gather plugin..."
claude plugin install must-gather@ai-helpers
echo "must-gather plugin installed."

ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

SYSTEM_PROMPT="You are a diligent senior OpenShift release engineer triaging failures.

**CRITICAL**: You have many ci and must-gather skills at your disposal. You MUST load the relevant skills using the Skill tool BEFORE you begin any work. Do NOT improvise or guess. This applies equally to subagents: instruct every subagent to review its available skills and load the appropriate ones before beginning its investigation. A subagent that does not load a skill will produce shallow, unreliable analysis.

After completing your analysis, you MUST use the Skill tool to invoke ci:payload-results-yaml and ci:payload-autodl-json to generate the structured output files. NEVER write these files directly — the skills enforce the canonical schema."

PHASE_ANALYSIS_START=$(date +%s)
CLAUDE_EXIT=0
timeout 3600 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    --append-system-prompt "${SYSTEM_PROMPT}" \
    -p "/ci:payload-analysis ${PAYLOAD_TAG} --snapshot-dir ${SNAPSHOT_DATA_DIR}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/claude-output.log" || CLAUDE_EXIT=$?

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

# Validate structured output files, retry up to 3 times if missing/invalid
VALIDATE_YAML="/opt/ai-helpers/plugins/ci/skills/payload-results-yaml/scripts/validate.py"
VALIDATE_JSON="/opt/ai-helpers/plugins/ci/skills/payload-autodl-json/scripts/validate.py"

for attempt in 1 2 3; do
    YAML_OK=false
    JSON_OK=false

    RESULTS_YAML=$(find . -maxdepth 1 -name "payload-results-*.yaml" -print -quit)
    RESULTS_JSON=$(find . -maxdepth 1 -name "payload-analysis-*-autodl.json" -print -quit)

    if [[ -n "${RESULTS_YAML}" ]] && python3 "${VALIDATE_YAML}" "${RESULTS_YAML}"; then
        YAML_OK=true
    fi
    if [[ -n "${RESULTS_JSON}" ]] && python3 "${VALIDATE_JSON}" "${RESULTS_JSON}"; then
        JSON_OK=true
    fi

    if $YAML_OK && $JSON_OK; then
        echo "Structured outputs validated (attempt ${attempt})."
        break
    fi

    if [[ "${attempt}" -eq 3 ]]; then
        echo "ERROR: Structured outputs still invalid after 3 attempts."
        PHASE_ANALYSIS_DURATION=$(( $(date +%s) - PHASE_ANALYSIS_START ))
        exit 1
    fi

    MISSING=""
    if ! $YAML_OK; then MISSING="ci:payload-results-yaml"; fi
    if ! $JSON_OK; then MISSING="${MISSING:+${MISSING} and }ci:payload-autodl-json"; fi
    echo "Attempt ${attempt}: Missing/invalid outputs (${MISSING}). Re-invoking Claude..."

    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 10 \
        -p "Your structured output files are missing or invalid. Use the Skill tool to invoke ${MISSING} to regenerate them now." \
        --verbose 2>&1 | tee -a "${ARTIFACT_DIR}/claude-output.log" || true
done

PHASE_ANALYSIS_DURATION=$(( $(date +%s) - PHASE_ANALYSIS_START ))

# Generate JUnit XML for timeout and phase duration tracking
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-ci.xml"
PHASE_PREFIX="[sig-claude]"
TIMEOUT_TESTCASE="${PHASE_PREFIX} Claude should complete in a reasonable time"
TOTAL_DURATION=$(( PHASE_WAIT_DURATION + PHASE_SNAPSHOT_DURATION + PHASE_ANALYSIS_DURATION + PHASE_NUDGE_DURATION ))

PHASE_CASES="  <testcase name=\"${PHASE_PREFIX} Phase: wait for blocking jobs\" time=\"${PHASE_WAIT_DURATION}\"/>
  <testcase name=\"${PHASE_PREFIX} Phase: snapshot\" time=\"${PHASE_SNAPSHOT_DURATION}\"/>
  <testcase name=\"${PHASE_PREFIX} Phase: analysis\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"

TIMEOUT_CASES=""
FAILURE_COUNT=0
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

PHASE_COUNT=3
if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    PHASE_COUNT=$((PHASE_COUNT + 1))
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
    -p "Write a very brief summary of your findings suitable for a Slack message. Include the payload tag and list the failed jobs. If you identified revert candidates, mention them. Include a brief, encouraging CI-related joke or pun. Plain text only, no markdown. 2-3 sentences max." \
    2>/dev/null) || SUMMARY=""

if [[ -n "${SLACK_WEBHOOK}" ]]; then
    SLACK_TEXT=":claude-thinking: *Payload Analysis for <${PAYLOAD_URL}|${PAYLOAD_TAG}>*

${SUMMARY:-No summary available.}

<${PROW_JOB_URL}|:point_right: View Full Analysis Report>
_Model: ${CLAUDE_MODEL}_"

    set +x
    jq -n --arg text "$SLACK_TEXT" '{text: $text}' | \
        curl -sf -X POST -H 'Content-type: application/json' -d @- \
        "${SLACK_WEBHOOK}" || echo "Warning: Failed to send Slack notification."
fi
