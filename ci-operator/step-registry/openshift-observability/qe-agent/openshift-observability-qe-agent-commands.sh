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
# 4. Validate and load the qe-agent skill by name.
#    Skills are hosted in the openshift/release step registry alongside this
#    step, under ci-operator/step-registry/openshift-observability/qe-agent/skills/.
#    Each team sets AGENT_SKILL to the name of their skill file (without .md).
# ---------------------------------------------------------------------------
if [[ -z "${AGENT_SKILL:-}" ]]; then
  echo "ERROR: AGENT_SKILL is not set — skipping qe-agent."
  exit 0
fi

# Reject names with path traversal or special characters — only allow
# alphanumeric, hyphens, and underscores.
if [[ ! "${AGENT_SKILL}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: AGENT_SKILL '${AGENT_SKILL}' contains invalid characters."
  echo "       Only alphanumeric characters, hyphens, and underscores are allowed."
  exit 0
fi

readonly SKILL_BASE_URL="https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/openshift-observability/qe-agent/skills"
readonly SKILL_URL="${SKILL_BASE_URL}/${AGENT_SKILL}.md"

echo "Fetching qe-agent skill '${AGENT_SKILL}' from ${SKILL_URL}..."

# --max-redirs 0: do not follow redirects — the allowlist check is on the
# constructed URL only, and a redirect could bypass it.
SKILL_CONTENT=$(curl -fsS --max-redirs 0 --connect-timeout 10 --max-time 30 --retry 3 "${SKILL_URL}") || true

if [[ -z "${SKILL_CONTENT}" ]]; then
  echo "ERROR: Failed to fetch skill '${AGENT_SKILL}' — check that the file exists at:"
  echo "       ci-operator/step-registry/openshift-observability/qe-agent/skills/${AGENT_SKILL}.md"
  exit 0
fi

# Guard against unexpectedly large payloads (100 KB limit).
# Use wc -c for a true byte count; ${#var} counts characters and would allow
# multi-byte UTF-8 content to bypass the limit.
readonly MAX_SKILL_BYTES=102400
SKILL_BYTE_COUNT=$(printf '%s' "${SKILL_CONTENT}" | wc -c)
if [[ ${SKILL_BYTE_COUNT} -gt ${MAX_SKILL_BYTES} ]]; then
  echo "ERROR: Skill content is ${SKILL_BYTE_COUNT} bytes, exceeds the ${MAX_SKILL_BYTES}-byte limit — skipping qe-agent."
  exit 0
fi

echo "Skill '${AGENT_SKILL}' loaded (${SKILL_BYTE_COUNT} bytes)."

# ---------------------------------------------------------------------------
# 5. Run Claude non-interactively with the skill as system prompt.
#
#    The full stream-json output is captured to a temp file so we can extract
#    cost/usage and a command audit log after Claude exits. The temp file is
#    NOT in ARTIFACT_DIR — it may contain cluster logs and API responses that
#    should not be uploaded to GCS. Only the derived extracts are saved there.
# ---------------------------------------------------------------------------
echo "Running qe-agent..."

_QE_STREAM=$(mktemp)
trap 'rm -f "${_QE_STREAM}"' EXIT

claude --print \
  --dangerously-skip-permissions \
  --allowedTools "Bash,Read,Write,Grep,Glob" \
  --model "${CLAUDE_MODEL:-claude-opus-4-6}" \
  --max-budget-usd 5 \
  --verbose \
  --output-format stream-json \
  --system-prompt "${SKILL_CONTENT}" \
  "SHARED_DIR=${SHARED_DIR} ARTIFACT_DIR=${ARTIFACT_DIR}. The test step context is in ${SHARED_DIR}/qe-agent-context.json and JUnit XML files are at ${SHARED_DIR}/qe-agent-junit-*.xml. Execute the skill starting with Step 0: read ${SHARED_DIR}/qe-agent-context.json." \
  > "${_QE_STREAM}" 2>&1 \
  || true

# ---------------------------------------------------------------------------
# Cost tracking — the terminal "result" record contains token counts and USD
# cost but no cluster data, so saving it to ARTIFACT_DIR is safe.
# ---------------------------------------------------------------------------
grep '"type":"result"' "${_QE_STREAM}" 2>/dev/null | head -1 \
  > "${ARTIFACT_DIR}/qe-agent-usage.json" || true

if [[ -s "${ARTIFACT_DIR}/qe-agent-usage.json" ]]; then
  _COST=$(jq -r  '.total_cost_usd   // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  _TURNS=$(jq -r '.num_turns        // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  _DUR_S=$(( $(jq -r '.duration_ms  // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0) / 1000 ))
  _IN=$(jq -r    '.usage.input_tokens  // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  _OUT=$(jq -r   '.usage.output_tokens // 0' "${ARTIFACT_DIR}/qe-agent-usage.json" 2>/dev/null || echo 0)
  echo "Cost: \$${_COST} | Turns: ${_TURNS} | Duration: ${_DUR_S}s | Tokens in: ${_IN} out: ${_OUT}"
fi

# ---------------------------------------------------------------------------
# Command audit log — every Bash tool call Claude made, command strings only.
# Cluster output (pod logs, events, API responses) is not captured here — only
# the command text, which contains no sensitive data and enables post-incident
# review of what Claude actually executed on the cluster.
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | "---\n" + (.input.command // "")
  ' "${_QE_STREAM}" 2>/dev/null \
  > "${ARTIFACT_DIR}/qe-agent-commands.log" || true

  if [[ -s "${ARTIFACT_DIR}/qe-agent-commands.log" ]]; then
    _CMD_COUNT=$(grep -c '^---$' "${ARTIFACT_DIR}/qe-agent-commands.log" 2>/dev/null || echo 0)
    echo "Audit log: ${_CMD_COUNT} Bash commands → ${ARTIFACT_DIR}/qe-agent-commands.log"
  fi
fi

echo "=== QE Agent Complete ==="

# Always exit 0 — best_effort post-step
exit 0
