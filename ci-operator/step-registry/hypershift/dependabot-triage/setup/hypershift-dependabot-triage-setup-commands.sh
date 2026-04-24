#!/bin/bash
set -euo pipefail

echo "=== HyperShift Dependabot Triage Setup ==="

# Verify Claude Code is available (Vertex AI authentication is handled via GOOGLE_APPLICATION_CREDENTIALS env var)
echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

# Restore .claude.json from backup if missing (can happen after image rebuilds)
CLAUDE_CONFIG="${HOME}/.claude/.claude.json"
if [ ! -f "$CLAUDE_CONFIG" ]; then
  LATEST_BACKUP=$(ls -t "${HOME}/.claude/backups/"*.backup.* 2>/dev/null | head -1)
  if [ -n "$LATEST_BACKUP" ]; then
    echo "WARNING: Claude config missing, restoring from backup: $LATEST_BACKUP"
    cp "$LATEST_BACKUP" "$CLAUDE_CONFIG"
  else
    echo "ERROR: Claude config missing and no backup found"
    exit 1
  fi
fi

echo "Setup complete"
