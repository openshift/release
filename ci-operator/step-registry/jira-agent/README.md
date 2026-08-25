# jira-agent Step Registry

Generic, reusable Jira Agent workflow for automated issue processing using Codex or Claude Code.

## Overview

This step registry provides a parameterized workflow that automatically picks up Jira issues,
solves them using the selected agent harness, runs code review, addresses findings, creates PRs,
and sends Slack notifications. GPT models use Codex; other models use Claude Code.

Teams create a thin wrapper workflow YAML that sets team-specific env vars and references
the generic step registry components. No bash scripting required.

Codex phases expose token counts and wall-clock duration from their JSONL output. Codex does
not provide pricing in the phase stream, so reports mark cost as unavailable rather than
reporting a false zero; Claude phases continue to use native OTEL cost metrics.

## Quick Start

```yaml
workflow:
  as: my-team-jira-agent
  steps:
    pre:
      - ref: jira-agent-setup
      - ref: jira-agent-github-app-auth
      - ref: jira-agent-slack-pr-notify
      - ref: jira-agent-claude-helpers
      - ref: jira-agent-jira-helpers
      - ref: jira-agent-git-helpers
    test:
      - ref: jira-agent-process
    post:
      - ref: jira-agent-report
    env:
      JIRA_AGENT_FORK_REPO: "my-org/my-repo"
      JIRA_AGENT_UPSTREAM_REPO: "openshift/my-repo"
      JIRA_AGENT_JQL: 'project = MYPROJ AND resolution = Unresolved AND labels = issue-for-agent'
```

See [ONBOARDING.md](ONBOARDING.md) for full setup instructions, environment variables,
and credentials configuration.
