#!/bin/bash
set -euo pipefail

echo "=== Medik8s E2E Failure Analyzer ==="

# ---------------------------------------------------------------------------
# 1. Construct GCS base path and wait for test step artifacts
# ---------------------------------------------------------------------------
JOB_NAME="${JOB_NAME:-unknown}"
BUILD_ID="${BUILD_ID:-unknown}"
JOB_TYPE="${JOB_TYPE:-}"
PULL_NUMBER="${PULL_NUMBER:-}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"

if [[ "$JOB_TYPE" == "presubmit" ]] && [[ -n "$PULL_NUMBER" ]]; then
  GCS_BUCKET_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  GCS_BUCKET_PATH="logs/${JOB_NAME}/${BUILD_ID}"
fi

GCSWEB_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
PROW_JOB_URL="${GCSWEB_BASE}/${GCS_BUCKET_PATH}"
ARTIFACTS_BASE="${GCSWEB_BASE}/${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}"

echo "Waiting for test step artifacts in GCS..."
FAILURE_DETECTED=false
FAILED_STEP=""
MAX_WAIT=600
POLL_INTERVAL=15
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
  for STEP_NAME in $TEST_STEPS; do
    FINISHED_JSON=$(curl -sL "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "$FINISHED_JSON" | jq -e '.passed == false' &>/dev/null; then
      echo "Detected test failure in ${STEP_NAME}/finished.json (waited ${WAITED}s)"
      FAILURE_DETECTED=true
      FAILED_STEP="$STEP_NAME"
      break 2
    elif echo "$FINISHED_JSON" | jq -e '.passed == true' &>/dev/null; then
      echo "Test step ${STEP_NAME} passed — skipping analysis."
      exit 0
    fi
  done

  echo "  Waiting for artifacts... (${WAITED}s/${MAX_WAIT}s)"
  sleep "$POLL_INTERVAL"
  WAITED=$((WAITED + POLL_INTERVAL))
done

if [[ "$FAILURE_DETECTED" == "false" ]]; then
  echo "Timed out waiting for test step artifacts after ${WAITED}s — skipping analysis."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Verify Claude Code CLI
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping analysis"
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"

# ---------------------------------------------------------------------------
# 3. Run Claude with the pre-installed ai-helpers skill
# ---------------------------------------------------------------------------
echo "Prow job URL: $PROW_JOB_URL"
echo "Failed step: $FAILED_STEP"

SYSTEM_PROMPT="IMPORTANT CI CONTEXT:
- You are running inside the CI job itself as a post-step.
- This step's artifact directory is: ${ARTIFACT_DIR}
- Other steps' artifacts (build-log, JUnit, intervals) are available via GCS at: ${PROW_JOB_URL}
- You have network access to download artifacts from GCS using curl.
- Write the final analysis report to: ${ARTIFACT_DIR}/failure-analysis.md
- Use --fast mode (do NOT use AskUserQuestion).
- Do NOT prompt for JIRA export — just write the markdown analysis.

MEDIK8S CONTEXT:
- Medik8s operators handle automated node remediation in OpenShift/Kubernetes clusters.
- Operators: self-node-remediation (SNR), node-healthcheck-operator (NHC), fence-agents-remediation (FAR), machine-deletion-remediation (MDR), node-maintenance-operator (NMO), storage-based-remediation (SBR).
- E2E tests use Ginkgo v2 + Gomega framework.
- Tests run on ephemeral OCP clusters provisioned via IPI-AWS."

echo ""
echo "Running Claude with /ci:prow-job-analyze-test-failure skill..."
echo ""

set +e
timeout 1200 claude -p "/ci:prow-job-analyze-test-failure ${PROW_JOB_URL} --fast" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch Skill" \
  --max-turns 100 \
  --model "$CLAUDE_MODEL" \
  --verbose \
  --output-format stream-json \
  2> "${ARTIFACT_DIR}/claude-failure-analysis.log" \
  | tee "${ARTIFACT_DIR}/claude-failure-analysis.json"
CLAUDE_EXIT=$?
set -e

if [[ "$CLAUDE_EXIT" -eq 124 ]]; then
  echo "Claude timed out — report may be incomplete"
fi

# ---------------------------------------------------------------------------
# 4. Extract token usage
# ---------------------------------------------------------------------------

TOKENS_JSON=$(grep '"type":"result"' "${ARTIFACT_DIR}/claude-failure-analysis.json" 2>/dev/null \
  | head -1 \
  | jq '{
      total_cost_usd: (.total_cost_usd // 0),
      duration_ms: (.duration_ms // 0),
      num_turns: (.num_turns // 0),
      input_tokens: (.usage.input_tokens // 0),
      output_tokens: (.usage.output_tokens // 0),
      cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
      cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0)
    }' 2>/dev/null \
  || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}')

COST=$(echo "$TOKENS_JSON" | jq -r '.total_cost_usd // 0')
DURATION_MS=$(echo "$TOKENS_JSON" | jq -r '.duration_ms // 0')
DURATION_S=$(printf '%.0f' "$(echo "${DURATION_MS} / 1000" | bc -l 2>/dev/null)" 2>/dev/null || echo 0)
NUM_TURNS=$(echo "$TOKENS_JSON" | jq -r '.num_turns // 0')

jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' \
  "${ARTIFACT_DIR}/claude-failure-analysis.json" \
  > "${ARTIFACT_DIR}/claude-failure-analysis-text.txt" 2>/dev/null || true

echo "$TOKENS_JSON" > "${SHARED_DIR}/claude-failure-analysis-tokens.json" 2>/dev/null || true

echo ""
echo "=== Failure Analysis Complete ==="
echo "Claude exit code: $CLAUDE_EXIT"
echo "Cost: \$${COST}"
echo "Duration: ${DURATION_S}s"
echo "Turns: ${NUM_TURNS}"
echo "Analysis: ${ARTIFACT_DIR}/failure-analysis.md"

exit 0
