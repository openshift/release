#!/bin/bash
set -euo pipefail

echo "=== Jira Agent Setup ==="

AGENT_MODEL="${CLAUDE_MODEL:-${JIRA_AGENT_MODEL:-gpt-5.6-sol}}"
AGENT_HARNESS="${JIRA_AGENT_HARNESS:-}"
AGENT_EFFORT="${JIRA_AGENT_EFFORT:-xhigh}"
OPENAI_API_KEY_PATH="${OPENAI_API_KEY_PATH:-/var/run/codex-openai-api-key/token}"
CODEX_HOME="${CODEX_HOME:-/workspace/jira-agent-codex-home}"
export CODEX_HOME
if [ -z "$AGENT_HARNESS" ]; then
  case "$AGENT_MODEL" in
    gpt-*) AGENT_HARNESS="codex" ;;
    *) AGENT_HARNESS="claude-code" ;;
  esac
fi

case "$AGENT_HARNESS:$AGENT_EFFORT" in
  claude-code:low|claude-code:medium|claude-code:high|claude-code:xhigh|claude-code:max|codex:minimal|codex:low|codex:medium|codex:high|codex:xhigh|codex:max)
    ;;
  *)
    echo "ERROR: Unsupported effort '$AGENT_EFFORT' for harness '$AGENT_HARNESS'"
    exit 1
    ;;
esac

echo "Selected harness: ${AGENT_HARNESS}"
echo "Selected model: ${AGENT_MODEL}"
echo "Selected effort: ${AGENT_EFFORT}"

case "$AGENT_HARNESS" in
  claude-code)
    echo "Verifying Claude Code CLI..."
    claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

    echo "Verifying Vertex AI credentials..."
    if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] || [ ! -r "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
      echo "ERROR: GOOGLE_APPLICATION_CREDENTIALS is not set or not readable"
      exit 1
    fi
    ;;
  codex)
    echo "Verifying Codex CLI..."
    codex --version || { echo "ERROR: Codex CLI not found"; exit 1; }
    if [ -z "${OPENAI_API_KEY:-}" ] && [ ! -r "$OPENAI_API_KEY_PATH" ]; then
      echo "ERROR: Codex requires OPENAI_API_KEY or a readable key at $OPENAI_API_KEY_PATH"
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Unsupported JIRA_AGENT_HARNESS=${AGENT_HARNESS}; expected claude-code or codex"
    exit 1
    ;;
esac

AGENT_CONFIG_FILE="${SHARED_DIR}/jira-agent-config.sh"
umask 077
{
  printf 'export AGENT_MODEL=%q\n' "$AGENT_MODEL"
  printf 'export AGENT_HARNESS=%q\n' "$AGENT_HARNESS"
  printf 'export AGENT_EFFORT=%q\n' "$AGENT_EFFORT"
  printf 'export OPENAI_API_KEY_PATH=%q\n' "$OPENAI_API_KEY_PATH"
  printf 'export CODEX_HOME=%q\n' "$CODEX_HOME"
} > "$AGENT_CONFIG_FILE"

echo "Setup complete"
