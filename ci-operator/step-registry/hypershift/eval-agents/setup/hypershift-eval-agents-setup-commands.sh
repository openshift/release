#!/bin/bash
set -euo pipefail

echo "=== HyperShift Eval Agents Setup ==="

echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

echo "Verifying Go toolchain..."
go version || { echo "ERROR: Go not found"; exit 1; }

echo "Setup complete"
