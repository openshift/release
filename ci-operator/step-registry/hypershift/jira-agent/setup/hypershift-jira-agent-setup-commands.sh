#!/bin/bash
set -euo pipefail

echo "=== HyperShift Jira Agent Setup ==="

# Clone HyperShift repository
echo "Cloning HyperShift repository..."
git clone https://github.com/openshift/hypershift /tmp/hypershift
cd /tmp/hypershift

# Configure git
echo "Configuring git..."
git config user.name "OpenShift CI Bot"
git config user.email "ci-bot@redhat.com"

# Setup GitHub CLI authentication
echo "Setting up GitHub authentication..."
gh auth login --with-token < /var/run/vault/hypershift-jira-agent-github-token/token

# Setup Claude Code authentication
echo "Setting up Claude Code authentication..."
export ANTHROPIC_API_KEY=$(cat /var/run/vault/hypershift-jira-agent-anthropic-api-key/key)

# Verify Claude Code is available
echo "Verifying Claude Code CLI..."
claude --version || { echo "ERROR: Claude Code CLI not found"; exit 1; }

# Test Claude Code can authenticate
echo "Testing Claude Code authentication..."
echo "print 'test'" | claude -p --output-format text > /dev/null || { echo "ERROR: Claude Code authentication failed"; exit 1; }

echo "✅ Setup complete"
