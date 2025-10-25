#!/bin/bash
# Local testing script for HyperShift Jira Agent
# This script simulates the periodic job flow for testing purposes

set -euo pipefail

echo "=== HyperShift Jira Agent Local Test ==="
echo ""

# Check prerequisites
echo "Checking prerequisites..."
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found. Install with: npm install -g @anthropics/claude-code"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found. Install from https://cli.github.com"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found. Install with: brew install jq"; exit 1; }

# Check for required environment variables
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ANTHROPIC_API_KEY environment variable not set"
  echo "Please set it with: export ANTHROPIC_API_KEY=your-key-here"
  exit 1
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARNING: GITHUB_TOKEN not set. You may not be able to create PRs."
  echo "Set it with: export GITHUB_TOKEN=your-token-here"
fi

echo "✅ All prerequisites met"
echo ""

# Clone HyperShift repository
HYPERSHIFT_DIR="/tmp/hypershift-test-$$"
echo "Cloning HyperShift repository to $HYPERSHIFT_DIR..."
git clone https://github.com/openshift/hypershift "$HYPERSHIFT_DIR"
cd "$HYPERSHIFT_DIR"

# Configure git
git config user.name "Test User"
git config user.email "test@example.com"

echo "✅ HyperShift repository ready"
echo ""

# Authenticate with GitHub (if token is set)
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "Authenticating with GitHub..."
  gh auth login --with-token <<< "$GITHUB_TOKEN"
  echo "✅ GitHub authentication complete"
  echo ""
fi

# Test Claude Code authentication
echo "Testing Claude Code authentication..."
echo "print 'test'" | claude -p --output-format text > /dev/null 2>&1 || { echo "ERROR: Claude Code authentication failed"; exit 1; }
echo "✅ Claude Code authentication successful"
echo ""

# Query Jira for test issues
echo "Querying Jira for issues..."
JIRA_QUERY='project in (OCPBUGS, CNTRLPLANE) AND resolution = Unresolved AND labels = issue-for-agent'
echo "JQL: $JIRA_QUERY"
echo ""

ISSUES=$(curl -s "https://issues.redhat.com/rest/api/2/search" \
  -G \
  --data-urlencode "jql=$JIRA_QUERY" \
  --data-urlencode 'fields=key,summary' \
  --data-urlencode 'maxResults=3' \
  | jq -r '.issues[]? | "\(.key) \(.fields.summary)"')

if [ -z "$ISSUES" ]; then
  echo "No issues found matching criteria. This is expected if no issues have the label."
  echo "You can manually test with a specific issue by running:"
  echo "  cd $HYPERSHIFT_DIR"
  echo "  echo '/jira-solve OCPBUGS-XXXXX origin' | claude -p --dangerously-skip-permissions"
  exit 0
fi

echo "Found issues:"
echo "$ISSUES"
echo ""

# Ask user if they want to process an issue
echo "Do you want to test processing one of these issues? (y/N)"
read -r ANSWER

if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
  echo "Skipping issue processing. Test complete."
  echo ""
  echo "To manually test, run:"
  echo "  cd $HYPERSHIFT_DIR"
  echo "  echo '/jira-solve ISSUE-KEY origin' | claude -p --dangerously-skip-permissions"
  exit 0
fi

# Get first issue
FIRST_ISSUE=$(echo "$ISSUES" | head -1 | awk '{print $1}')
echo ""
echo "Testing with issue: $FIRST_ISSUE"
echo "=========================================="

# Run /jira-solve command
echo "/jira-solve $FIRST_ISSUE origin" | claude -p \
  --output-format json \
  --dangerously-skip-permissions \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch SlashCommand" \
  --max-turns 30 \
  | jq '.'

echo ""
echo "=========================================="
echo "Test complete!"
echo ""
echo "Cleanup: rm -rf $HYPERSHIFT_DIR"
