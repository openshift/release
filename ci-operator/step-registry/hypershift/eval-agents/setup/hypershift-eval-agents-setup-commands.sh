#!/bin/bash
set -euo pipefail

echo "=== HyperShift Eval Agents Setup ==="

echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

echo "Installing Node.js and npm..."
dnf install -y nodejs npm || yum install -y nodejs npm
node --version
npm --version

echo "Setup complete"
