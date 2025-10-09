# HyperShift Jira Agent Container Image

This container image is used by the HyperShift Jira Agent periodic job to automatically process Jira issues using Claude Code.

## Contents

- **Claude Code CLI**: For executing `/jira-solve` commands
- **GitHub CLI (gh)**: For creating pull requests
- **jq**: For parsing JSON responses from Jira API and Claude
- **git**: For cloning repositories and creating commits
- **kubectl**: For managing state in ConfigMaps (from base image)

## Base Image

Uses `quay.io/openshift/origin-cli:latest` which provides:
- kubectl
- oc (OpenShift CLI)
- Basic shell utilities

## Build

This image is built automatically by CI when changes are made to this directory.

## Usage

This image is referenced in the step-registry workflow:
`ci-operator/step-registry/hypershift/jira-agent/hypershift-jira-agent-workflow.yaml`

The workflow mounts secrets for:
- Anthropic API key (for Claude Code)
- GitHub token (for creating PRs)

## Local Testing

### Option 1: Use the Test Script (Recommended)

The easiest way to test the workflow locally:

```bash
# Set required environment variables
export ANTHROPIC_API_KEY=your-anthropic-key
export GITHUB_TOKEN=your-github-token

# Run the test script
./tools/hypershift-jira-agent/test-locally.sh
```

**What the script does:**
1. Verifies prerequisites (claude, gh, jq)
2. Checks environment variables are set
3. Clones HyperShift repo to temp directory
4. Queries Jira for real issues with `issue-for-agent` label
5. Optionally processes one issue with `/jira-solve`
6. Interactive - asks for confirmation before processing

**Prerequisites:**
- Claude Code CLI: `npm install -g @anthropics/claude-code`
- GitHub CLI: Install from https://cli.github.com
- jq: `brew install jq` (macOS) or `apt install jq` (Linux)

### Option 2: Manual Testing

Test the workflow manually:

```bash
cd /tmp
git clone https://github.com/openshift/hypershift
cd hypershift
export ANTHROPIC_API_KEY=your-key
echo "/jira-solve OCPBUGS-12345 origin" | claude -p --dangerously-skip-permissions
```

### Option 3: Test the Container Image

Build and test the container image locally:

```bash
# Build the image
podman build -t hypershift-jira-agent:local tools/hypershift-jira-agent/

# Run interactively
podman run -it --rm \
  -e ANTHROPIC_API_KEY=your-key-here \
  hypershift-jira-agent:local \
  bash

# Inside the container, test Claude Code
claude --version
echo "print 'test'" | claude -p
```
