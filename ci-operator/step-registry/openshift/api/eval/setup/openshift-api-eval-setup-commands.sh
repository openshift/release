#!/bin/bash
set -euo pipefail

echo "=== OpenShift API Review Eval Setup ==="

mkdir -p "${HOME}/.claude"
touch "${HOME}/.claude/.claude.json"

echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

echo "Verifying Go toolchain..."
go version || { echo "ERROR: Go not found"; exit 1; }

echo "Setup complete"
