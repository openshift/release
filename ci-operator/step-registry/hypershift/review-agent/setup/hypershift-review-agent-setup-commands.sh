#!/bin/bash
set -euo pipefail

echo "=== HyperShift Review Agent Setup ==="

# Verify Claude Code is available (Vertex AI authentication is handled via GOOGLE_APPLICATION_CREDENTIALS env var)
echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

echo "Setup complete"
