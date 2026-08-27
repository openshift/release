#!/bin/bash
set -euo pipefail

echo "=== Libvirt E2E Failure Analyzer ==="

JOB_NAME="${JOB_NAME:-unknown}"
BUILD_ID="${BUILD_ID:-unknown}"
JOB_TYPE="${JOB_TYPE:-}"
PULL_NUMBER="${PULL_NUMBER:-}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"

if [[ -z "${TEST_NAME:-}" ]]; then
  if [[ "${JOB_NAME}" =~ (ocp-[^/]+)$ ]]; then
    TEST_NAME="${BASH_REMATCH[1]}"
  elif [[ "${JOB_NAME}" =~ (e2e-[^/]+)$ ]]; then
    TEST_NAME="${BASH_REMATCH[1]}"
  else
    echo "ERROR: TEST_NAME is empty and could not be derived from JOB_NAME=${JOB_NAME} — skipping analysis."
    exit 0
  fi
fi

if [[ "${JOB_TYPE}" == "presubmit" && -n "${PULL_NUMBER}" ]]; then
  GCS_BUCKET_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  GCS_BUCKET_PATH="logs/${JOB_NAME}/${BUILD_ID}"
fi

GCSWEB_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
PROW_JOB_URL="${GCSWEB_BASE}/${GCS_BUCKET_PATH}"
ARTIFACTS_BASE="${GCSWEB_BASE}/${GCS_BUCKET_PATH}/artifacts/${TEST_NAME}"

echo "Waiting for test step artifacts in GCS (TEST_NAME=${TEST_NAME} ARCH=${ARCH:-unset})..."
FAILURE_DETECTED=false
FAILED_STEP=""
MAX_WAIT=600
POLL_INTERVAL=15
START_TIME=${SECONDS}

while (( (SECONDS - START_TIME) < MAX_WAIT )); do
  for STEP_NAME in ${TEST_STEPS}; do
    FINISHED_JSON=$(curl -sL --connect-timeout 10 --max-time 20 \
      "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "${FINISHED_JSON}" | jq -e '.passed == false' &>/dev/null; then
      echo "Detected failure in ${STEP_NAME}/finished.json (elapsed $((SECONDS - START_TIME))s)"
      FAILURE_DETECTED=true
      FAILED_STEP="${STEP_NAME}"
      break 2
    fi
  done

  all_passed=true
  saw_any=false
  for STEP_NAME in ${TEST_STEPS}; do
    FINISHED_JSON=$(curl -sL --connect-timeout 10 --max-time 20 \
      "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "${FINISHED_JSON}" | jq -e '.passed == true' &>/dev/null; then
      saw_any=true
      continue
    fi
    all_passed=false
    break
  done
  if [[ "${saw_any}" == "true" && "${all_passed}" == "true" ]]; then
    echo "Listed test steps passed — skipping analysis."
    exit 0
  fi

  echo "  Waiting for artifacts... ($((SECONDS - START_TIME))s/${MAX_WAIT}s)"
  sleep "${POLL_INTERVAL}"
done

if [[ "${FAILURE_DETECTED}" == "false" ]]; then
  echo "Timed out waiting for failed-step artifacts after $((SECONDS - START_TIME))s — skipping analysis."
  exit 0
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping analysis"
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"
echo "Failed step: ${FAILED_STEP}"

# Runtime CI context is always prepended. SYSTEM_PROMPT is the platform-specific
# override (libvirt by default; PowerVC and others can set it on the step).
CI_CONTEXT="IMPORTANT CI CONTEXT:
- You are running inside the CI job itself as a post-step.
- This step's artifact directory is: ${ARTIFACT_DIR}
- Other steps' artifacts (build-log, JUnit, install, gather) are available via GCS at: ${PROW_JOB_URL}
- You may use curl only to download artifacts from this GCS job URL. Do not fetch unrelated URLs.
- Write the final analysis report to: ${ARTIFACT_DIR}/failure-analysis.md
- Use --fast mode (do NOT use AskUserQuestion).
- Do NOT prompt for JIRA export — just write the markdown analysis.
- NEVER read files under /var/run/
- NEVER access credential or token files
- ARCH is ${ARCH:-unknown}."

FULL_PROMPT="${CI_CONTEXT}

${SYSTEM_PROMPT:-}"

echo ""
echo "Running Claude with /ci:prow-job-analysis skill..."
echo ""

# Bash is required so /ci:prow-job-analysis can curl GCS artifacts.
# WebFetch is omitted to block a prompt-injection exfiltration path.
# Disallowed Bash patterns block reads of the Vertex SA key.
set +e
timeout 1200 claude -p "/ci:prow-job-analysis ${PROW_JOB_URL} --fast" \
  --append-system-prompt "${FULL_PROMPT}" \
  --allowedTools "Bash Read Write Edit Grep Glob Skill" \
  --disallowedTools "WebFetch Bash(cat*claude-code-service-account*) Bash(cat*/var/run/*) Bash(curl*google-token*) Bash(env*) Bash(printenv*)" \
  --max-turns 100 \
  --model "${CLAUDE_MODEL}" \
  --verbose \
  --output-format stream-json \
  > "${ARTIFACT_DIR}/claude-failure-analysis.json" \
  2> "${ARTIFACT_DIR}/claude-failure-analysis.log"
CLAUDE_EXIT=$?
set -e

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
  echo "Claude timed out — report may be incomplete"
fi

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

echo "${TOKENS_JSON}" > "${SHARED_DIR}/claude-failure-analysis-tokens.json" 2>/dev/null || true

echo ""
echo "=== Failure Analysis Complete ==="
echo "Claude exit code: ${CLAUDE_EXIT}"
echo "Analysis: ${ARTIFACT_DIR}/failure-analysis.md"

exit 0
