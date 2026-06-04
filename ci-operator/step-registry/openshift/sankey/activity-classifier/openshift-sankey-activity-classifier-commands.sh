#!/bin/bash
set -euo pipefail

echo "=== Sankey Activity Type Classifier ==="
echo "Project: ${SANKEY_PROJECT_KEY}"
echo "Issue Type: ${SANKEY_ISSUE_TYPE}"
echo "Max Issues: ${SANKEY_MAX_ISSUES}"
echo "Dry Run: ${SANKEY_DRY_RUN}"
echo "Model: ${CLAUDE_MODEL}"

claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

# Disable tracing for credential handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

echo "Loading Jira credentials..."
JIRA_API_TOKEN=""
if [ -f "${JIRA_API_TOKEN_PATH}" ]; then
    JIRA_API_TOKEN=$(cat "${JIRA_API_TOKEN_PATH}")
    echo "Jira API token loaded."
else
    echo "ERROR: Jira API token not found at ${JIRA_API_TOKEN_PATH}"
    exit 1
fi

JIRA_USERNAME=""
if [ -f "${JIRA_USERNAME_PATH}" ]; then
    JIRA_USERNAME=$(cat "${JIRA_USERNAME_PATH}")
    echo "Jira username loaded."
else
    echo "ERROR: Jira username not found at ${JIRA_USERNAME_PATH}"
    exit 1
fi

echo "Configuring mcp-atlassian MCP server..."
claude mcp add \
    -e JIRA_URL="${JIRA_URL}" \
    -e JIRA_API_TOKEN="${JIRA_API_TOKEN}" \
    -e JIRA_USERNAME="${JIRA_USERNAME}" \
    --transport stdio \
    jira -- uvx mcp-atlassian@0.21.0
echo "MCP server configured."

$WAS_TRACING && set -x

WORKDIR=$(mktemp -d)
REPORT_DIR="${ARTIFACT_DIR}/sankey-classifier"
mkdir -p "${REPORT_DIR}"

cleanup() {
    echo "Collecting artifacts..."
    for f in classifications.json report.md issues.json; do
        if [ -f "${WORKDIR}/.work/activity-type-classifier/${f}" ]; then
            cp "${WORKDIR}/.work/activity-type-classifier/${f}" "${REPORT_DIR}/"
        fi
    done
    [ -f "/tmp/claude-sankey-output.json" ] && cp /tmp/claude-sankey-output.json "${REPORT_DIR}/" || true
    [ -f "/tmp/claude-sankey-output.log" ] && cp /tmp/claude-sankey-output.log "${REPORT_DIR}/" || true
}
trap cleanup EXIT TERM INT

echo "Using built-in jira@ai-helpers plugin (categorize-activity-types skill)"

cd "${WORKDIR}"
mkdir -p .work/activity-type-classifier

AUTONOMOUS_OVERRIDES="You are running autonomously in CI. Apply the following overrides:
- Max issues: Process at most ${SANKEY_MAX_ISSUES} issues per run.
- No interactive prompts: Do not use AskUserQuestion or wait for input.
- Error handling: Log errors and continue processing remaining issues.
- Dry run mode: ${SANKEY_DRY_RUN}. When dry run is true, do NOT apply any updates to Jira (skip Phase 4 entirely). Classify issues and generate the report and classifications.json showing what WOULD be set, but do not call jira_update_issue. When dry run is false, apply updates immediately without asking for user confirmation.
- Jira access: You MUST use the MCP Jira tools (mcp__jira__*) for ALL Jira operations. Do NOT use Bash, curl, acli, or any other method to access Jira. The MCP server named 'jira' is configured and available."

PROCESS_START=$(date +%s)

DRY_RUN_FLAG=""
if [[ "${SANKEY_DRY_RUN}" == "true" ]]; then
    DRY_RUN_FLAG="--dry-run"
fi

echo "Starting Claude classification..."
set +e
claude \
    -p "/jira:batch-categorize-activity-types ${SANKEY_PROJECT_KEY} --type ${SANKEY_ISSUE_TYPE} --limit ${SANKEY_MAX_ISSUES} ${DRY_RUN_FLAG}" \
    --append-system-prompt "${AUTONOMOUS_OVERRIDES}" \
    --allowedTools "mcp__jira__* Bash Read Write Grep Glob Skill" \
    --max-turns 100 \
    --model "${CLAUDE_MODEL}" \
    --output-format stream-json \
    --verbose \
    2> /tmp/claude-sankey-output.log \
    | tee /tmp/claude-sankey-output.json
EXIT_CODE=$?
set -e

PROCESS_END=$(date +%s)
PROCESS_DURATION=$((PROCESS_END - PROCESS_START))

echo ""
echo "Claude exited with code: ${EXIT_CODE}"
echo "Processing duration: ${PROCESS_DURATION}s"

# Extract token usage
grep '"type":"result"' /tmp/claude-sankey-output.json \
    | tail -1 \
    | jq '{
        total_cost_usd: (.total_cost_usd // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0),
        cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
        model: (.modelUsage | keys[0] // "unknown"),
        duration_seconds: '${PROCESS_DURATION}',
        num_turns: (.num_turns // 0)
    }' > "${REPORT_DIR}/token-usage.json" 2>/dev/null || echo '{"error": "failed to extract token usage"}' > "${REPORT_DIR}/token-usage.json"

echo "Done. Duration: ${PROCESS_DURATION}s, Exit code: ${EXIT_CODE}"
