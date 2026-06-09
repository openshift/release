#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== OpenShift Observability QE Agent ==="

# ---------------------------------------------------------------------------
# 1. Verify the flat context file written by the test step is present.
#    SHARED_DIR only propagates flat files between steps — subdirectories
#    created in a test step are not visible in subsequent post steps.
# ---------------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/qe-agent-context.json" ]]; then
  echo "No ${SHARED_DIR}/qe-agent-context.json found — test steps may not have run or produced no results."
  echo "Skipping qe-agent."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Check whether the test step reported failures.
# ---------------------------------------------------------------------------
if ! grep -q '"has_test_failures": true' "${SHARED_DIR}/qe-agent-context.json" 2>/dev/null; then
  echo "All tests passed — no failures detected. Skipping qe-agent."
  exit 0
fi

echo "Test failures detected — proceeding with qe-agent analysis."

# ---------------------------------------------------------------------------
# 3. Verify Claude CLI is available
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found — skipping qe-agent."
  exit 0
fi

echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'unknown')"

# ---------------------------------------------------------------------------
# 4. Validate and load the qe-agent skill from the URL provided by the job.
#    Only URLs under https://raw.githubusercontent.com/openshift/ are trusted.
# ---------------------------------------------------------------------------
if [[ -z "${AGENT_SKILL_URL:-}" ]]; then
  echo "ERROR: AGENT_SKILL_URL is not set — skipping qe-agent."
  exit 0
fi

readonly SKILL_URL_ALLOWLIST="https://raw.githubusercontent.com/openshift/"
if [[ "${AGENT_SKILL_URL}" != "${SKILL_URL_ALLOWLIST}"* ]]; then
  echo "ERROR: AGENT_SKILL_URL '${AGENT_SKILL_URL}' is not from an allowed host."
  echo "       Skill URLs must start with: ${SKILL_URL_ALLOWLIST}"
  exit 0
fi

echo "Fetching qe-agent skill from ${AGENT_SKILL_URL}..."
SKILL_CONTENT=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${AGENT_SKILL_URL}") || true

if [[ -z "${SKILL_CONTENT}" ]]; then
  echo "ERROR: Failed to fetch skill from ${AGENT_SKILL_URL} — skipping qe-agent."
  exit 0
fi

echo "Skill loaded."

# ---------------------------------------------------------------------------
# 5. Run Claude non-interactively with the skill as system prompt
# ---------------------------------------------------------------------------
echo "Running qe-agent..."

claude --print \
  --dangerously-skip-permissions \
  --allowedTools "Bash,Read,Write,Grep,Glob,WebFetch" \
  --model "${CLAUDE_MODEL}" \
  --verbose \
  --output-format stream-json \
  --system-prompt "${SKILL_CONTENT}" \
  "SHARED_DIR=${SHARED_DIR} ARTIFACT_DIR=${ARTIFACT_DIR}. The test step context is in ${SHARED_DIR}/qe-agent-context.json and JUnit XML files are at ${SHARED_DIR}/qe-agent-junit-*.xml. Execute the skill starting with Step 0: read ${SHARED_DIR}/qe-agent-context.json." \
  2>&1 | tee "${ARTIFACT_DIR}/qe-agent-output.json" || true

echo "=== QE Agent Complete ==="

# Always exit 0 — best_effort post-step
exit 0
