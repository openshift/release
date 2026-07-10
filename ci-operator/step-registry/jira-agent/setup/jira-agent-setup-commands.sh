#!/bin/bash
set -euo pipefail

echo "=== Jira Agent Setup ==="

# Verify Claude Code is available (Vertex AI authentication is handled via GOOGLE_APPLICATION_CREDENTIALS env var)
echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

echo "Verifying Vertex AI credentials..."
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] || [ ! -r "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
  echo "ERROR: GOOGLE_APPLICATION_CREDENTIALS is not set or not readable"
  exit 1
fi

echo "Setup complete"
