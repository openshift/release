#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Metrics Emission ==="

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

# Read metadata written by the main step (jira-solver or review-responder)
if [[ ! -f "${SHARED_DIR}/metrics-metadata.json" ]]; then
    echo "No metrics metadata found in SHARED_DIR. Skipping metrics emission."
    exit 0
fi

METADATA=$(cat "${SHARED_DIR}/metrics-metadata.json")
AGENT=$(echo "${METADATA}" | jq -r '.agent')
PHASE=$(echo "${METADATA}" | jq -r '.phase')
ISSUE_KEY=$(echo "${METADATA}" | jq -r '.issue_key')
RESULT=$(echo "${METADATA}" | jq -r '.result')
PR_URL=$(echo "${METADATA}" | jq -r '.pr_url // ""')
UPSTREAM_REPO=$(echo "${METADATA}" | jq -r '.upstream_repo')
NUM_REVIEW_ROUNDS=$(echo "${METADATA}" | jq -r '.num_review_rounds // 0')

# Phase durations (solver: setup/solve/pr, review-responder: review)
PHASE_DURATIONS=$(echo "${METADATA}" | jq -r '.phase_durations // {}')

echo "Agent: ${AGENT}, Phase: ${PHASE}, Issue: ${ISSUE_KEY}"

# --- Session metrics (cost, tokens) for BigQuery claude_session_metrics table ---
# Skip autodl emission for eval runs to keep test data out of BigQuery
if [[ "${EVAL_MODE:-}" != "true" ]]; then
    if [[ -f "${EXTRACT_METRICS}" ]] && [[ -f "${OTEL_LOG}" ]]; then
        echo "Extracting session metrics..."
        python3 "${EXTRACT_METRICS}" "${OTEL_LOG}" "${ARTIFACT_DIR}/claude-session-metrics-autodl.json" \
            2>&1 || echo "Warning: Failed to extract session metrics"
    fi

    # --- Domain autodl for BigQuery jira_agent table ---
    echo "Generating domain autodl..."
    ANALYZED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Base schema (all agents)
    SCHEMA='{
      session_id: "string",
      agent: "string",
      phase: "string",
      issue_key: "string",
      pr_url: "string",
      result: "string",
      upstream_repo: "string",
      analyzed_at: "string",
      job_name: "string",
      build_id: "string"
    }'

    # Base row (all agents)
    ROW=$(jq -n \
        --arg agent "${AGENT}" \
        --arg phase "${PHASE}" \
        --arg issue_key "${ISSUE_KEY}" \
        --arg pr_url "${PR_URL}" \
        --arg result "${RESULT}" \
        --arg upstream_repo "${UPSTREAM_REPO}" \
        --arg analyzed_at "${ANALYZED_AT}" \
        --arg job_name "${JOB_NAME:-}" \
        --arg build_id "${BUILD_ID:-}" \
        '{
          session_id: "",
          agent: $agent,
          phase: $phase,
          issue_key: $issue_key,
          pr_url: $pr_url,
          result: $result,
          upstream_repo: $upstream_repo,
          analyzed_at: $analyzed_at,
          job_name: $job_name,
          build_id: $build_id
        }')

    # Add num_review_rounds for review-responder
    if [[ "${AGENT}" == "trt-review-responder" ]]; then
        SCHEMA=$(echo "${SCHEMA}" | jq '. + {num_review_rounds: "integer"}')
        ROW=$(echo "${ROW}" | jq --argjson num_review_rounds "${NUM_REVIEW_ROUNDS}" '. + {num_review_rounds: $num_review_rounds}')
    fi

    jq -n \
        --argjson schema "${SCHEMA}" \
        --argjson row "${ROW}" \
        '{
          table_name: "jira_agent",
          schema: $schema,
          schema_mapping: null,
          rows: [$row],
          chunk_size: 0,
          expiration_days: 0,
          partition_column: ""
        }' > "${ARTIFACT_DIR}/jira-agent-trt-autodl.json"
    echo "Domain autodl written to ${ARTIFACT_DIR}/jira-agent-trt-autodl.json"
fi

# --- JUnit XML for phase duration tracking (always emit, even in eval) ---
echo "Generating JUnit XML..."
JUNIT_FILE="${ARTIFACT_DIR}/junit_agentic-trt-${PHASE}.xml"
PHASE_PREFIX="[sig-trt-agentic]"

if [[ "${AGENT}" == "trt-jira-solver" ]]; then
    # Solver: setup/solve/pr phases + timeout check
    PHASE_SETUP=$(echo "${PHASE_DURATIONS}" | jq -r '.setup // 0')
    PHASE_SOLVE=$(echo "${PHASE_DURATIONS}" | jq -r '.solve // 0')
    PHASE_PR=$(echo "${PHASE_DURATIONS}" | jq -r '.pr // 0')
    TOTAL_DURATION=$(( PHASE_SETUP + PHASE_SOLVE + PHASE_PR ))
    CLAUDE_EXIT=$(echo "${METADATA}" | jq -r '.claude_exit // 0')

    FAILURE_COUNT=0
    TIMEOUT_CASE=""
    if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
        FAILURE_COUNT=1
        TIMEOUT_CASE="  <testcase name=\"${PHASE_PREFIX} Claude should complete in a reasonable time\" time=\"${PHASE_SOLVE}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
  </testcase>"
    else
        TIMEOUT_CASE="  <testcase name=\"${PHASE_PREFIX} Claude should complete in a reasonable time\" time=\"${PHASE_SOLVE}\"/>"
    fi

    TEST_COUNT=4
    cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="agentic-trt-jira-solver" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
  <testcase name="${PHASE_PREFIX} Phase: setup" time="${PHASE_SETUP}"/>
  <testcase name="${PHASE_PREFIX} Phase: solve" time="${PHASE_SOLVE}"/>
  <testcase name="${PHASE_PREFIX} Phase: pr-creation" time="${PHASE_PR}"/>
${TIMEOUT_CASE}
</testsuite>
EOF

elif [[ "${AGENT}" == "trt-review-responder" ]]; then
    # Review-responder: single review phase + summary
    PHASE_REVIEW=$(echo "${PHASE_DURATIONS}" | jq -r '.review // 0')
    ITERATION=$(echo "${METADATA}" | jq -r '.iteration // 0')
    IDLE_STREAK=$(echo "${METADATA}" | jq -r '.idle_streak // 0')

    cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="agentic-trt-review-responder" tests="2" failures="0" time="${PHASE_REVIEW}">
  <testcase name="${PHASE_PREFIX} Phase: review" time="${PHASE_REVIEW}"/>
  <testcase name="${PHASE_PREFIX} Review rounds completed" time="0">
    <system-out>review_rounds=${NUM_REVIEW_ROUNDS} iterations=${ITERATION} idle_streak=${IDLE_STREAK}</system-out>
  </testcase>
</testsuite>
EOF
fi

echo "JUnit XML written to ${JUNIT_FILE}"
echo "=== TRT Metrics Emission Complete ==="
