# Review Agent

Generic workflow for automated PR review comment handling using Claude Code.

## Overview

This workflow processes a single PR per invocation:

1. **Setup**: Generates GitHub App tokens and verifies Claude Code CLI availability
2. **Process**: Addresses review comments using `/openshift-developer:address-review-pr`
3. **Report**: Generates HTML report with token usage, cost estimates, and action badges

## Architecture

Teams onboard by creating a thin wrapper workflow that sets two environment variables:

| Variable | Purpose |
|---|---|
| `REVIEW_AGENT_FORK_REPO` | Fork repo URL to clone and push to |
| `REVIEW_AGENT_UPSTREAM_REPO` | Upstream `owner/repo` for `gh pr` operations |

All other values (clone dir, git remote URL, system prompt, PR links, report footer, telemetry repo field) are derived from these two.

Teams with a different credential secret create thin ref YAML wrappers pointing to the generic commands scripts with their own `credentials:` block. See [ONBOARDING.md](ONBOARDING.md).

## Steps

| Step | Phase | Purpose |
|---|---|---|
| `jira-agent-github-app-auth` | pre | Writes `github-app-auth.sh` library to `SHARED_DIR` |
| `review-agent-setup` | pre | Verifies Claude CLI, configures Vertex AI auth |
| `review-agent-process` | test | Clones repo, addresses review comments via Claude |
| `review-agent-report` | post | Generates HTML report from processing output |

## Onboarding

See [ONBOARDING.md](ONBOARDING.md) for step-by-step instructions to add your team.

## Current Consumers

- **HyperShift**: `ci-operator/step-registry/hypershift/review-agent/`
