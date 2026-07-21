# HyperShift Review Agent Workflow

HyperShift-specific wrapper for the generic [review-agent](../../review-agent/) workflow.

## How It Works

This workflow delegates to the generic `review-agent` steps with HyperShift-specific
configuration:

| Variable | Value |
|---|---|
| `REVIEW_AGENT_FORK_REPO` | `https://github.com/hypershift-community/hypershift` |
| `REVIEW_AGENT_UPSTREAM_REPO` | `openshift/hypershift` |

Credentials use the `hypershift-team-claude-prow` secret (configured in the generic step refs).

## Jobs

### Periodic Job

Configured in `ci-operator/config/openshift/hypershift/openshift-hypershift-main.yaml`:

```yaml
- as: periodic-review-agent
  cron: '@yearly'
  steps:
    workflow: hypershift-review-agent
```

### On-Demand Single PR Job

```yaml
- always_run: false
  as: address-review-comments
  optional: true
  skip_if_only_changed: .*
  steps:
    workflow: hypershift-review-agent-trigger
```

Run `/test address-review-comments` on any PR in openshift/hypershift.

## Trigger Step

The `hypershift-review-agent-trigger` workflow remains HyperShift-specific. It triggers
the periodic review-agent job via Gangway instead of running the agent inline, avoiding
the presubmit aborting when the agent pushes to the PR branch.

## Generic Documentation

For full documentation on the review agent architecture, onboarding new teams,
environment variables, and troubleshooting, see the [generic review-agent guide](../../review-agent/ONBOARDING.md).
