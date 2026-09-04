#!/bin/bash
set -euo pipefail

echo "=== oc-mirror E2E Failure Analyzer ==="

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

echo "Waiting for test step artifacts in GCS (TEST_NAME=${TEST_NAME}, TEST_STEPS=${TEST_STEPS})..."
FAILURE_DETECTED=false
FAILED_STEP=""
MAX_WAIT=600
POLL_INTERVAL=15
WAITED=0

while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
  for STEP_NAME in ${TEST_STEPS}; do
    FINISHED_JSON=$(curl -sL --connect-timeout 10 --max-time 20 "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "${FINISHED_JSON}" | jq -e '.passed == false' &>/dev/null; then
      echo "Detected failure in ${STEP_NAME}/finished.json (waited ${WAITED}s)"
      FAILURE_DETECTED=true
      FAILED_STEP="${STEP_NAME}"
      break 2
    fi
  done

  all_passed=true
  saw_any=false
  for STEP_NAME in ${TEST_STEPS}; do
    FINISHED_JSON=$(curl -sL --connect-timeout 10 --max-time 20 "${ARTIFACTS_BASE}/${STEP_NAME}/finished.json" 2>/dev/null || true)
    if echo "${FINISHED_JSON}" | jq -e '.passed == true' &>/dev/null; then
      saw_any=true
      continue
    fi
    if echo "${FINISHED_JSON}" | jq -e '.passed == false' &>/dev/null; then
      all_passed=false
      break
    fi
    all_passed=false
  done
  if [[ "${saw_any}" == "true" && "${all_passed}" == "true" ]]; then
    echo "Listed test steps passed — skipping analysis."
    exit 0
  fi

  echo "  Waiting for artifacts... (${WAITED}s/${MAX_WAIT}s)"
  sleep "${POLL_INTERVAL}"
  WAITED=$((WAITED + POLL_INTERVAL))
done

if [[ "${FAILURE_DETECTED}" == "false" ]]; then
  echo "Timed out waiting for failed-step artifacts after ${WAITED}s — skipping analysis."
  exit 0
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping analysis"
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"
echo "Failed step: ${FAILED_STEP}"

SYSTEM_PROMPT="IMPORTANT CI CONTEXT:
- You are running inside the CI job itself as a post-step.
- This step's artifact directory is: ${ARTIFACT_DIR}
- Other steps' artifacts (build-log, JUnit, install, gather) are available via GCS at: ${PROW_JOB_URL}
- You have network access to download artifacts from GCS using curl.
- Write the final analysis report to: ${ARTIFACT_DIR}/failure-analysis.md
- Use --fast mode (do NOT use AskUserQuestion).
- Do NOT prompt for JIRA export — just write the markdown analysis.

OC-MIRROR CONTEXT:
- This step analyzes e2e jobs that install a disconnected/mirrored OpenShift
  cluster using oc-mirror to mirror the release payload into a registry.
- Depending on the workflow under test, mirroring is done either:
    * directly, mirror-to-mirror (source registry -> mirror registry) via the
      mirror-images-by-oc-mirror step (MIRROR_BIN=oc-mirror), or
    * in two phases: mirror-to-disk (source registry -> disk archive) via
      mirror-images-by-oc-mirror-to-disk, then disk-to-mirror (disk archive ->
      mirror registry, without internet access) via
      mirror-images-by-oc-mirror-from-disk.
- The cluster is installed pointing at the mirror registry using IDMS/ICSP
  generated from the mirroring step(s), then the standard openshift-e2e-test
  suite is executed through the bastion proxy.
- Prefer evidence from oc-mirror logs, install logs, build-log.txt, and junit
  results over speculation. Common failure classes: oc-mirror registry auth
  or archive errors, IDMS/ICSP mirror misconfiguration, and proxy/network
  connectivity failures during install or e2e."

echo ""
echo "Running Claude with /ci:prow-job-analysis skill..."
echo ""

set +e
timeout 1200 claude -p "/ci:prow-job-analysis ${PROW_JOB_URL} --fast" \
  --append-system-prompt "${SYSTEM_PROMPT}" \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch Skill" \
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
