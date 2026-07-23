# Review Agent Onboarding Guide

This guide walks you through onboarding your team to the generic review-agent workflow for automated PR review comment handling.

## Prerequisites

### Authentication

The review-agent supports two authentication modes:

#### PAT Mode (Works out of the box)

A GitHub classic PAT (`gh-pat`) is already configured in the shared `hypershift-team-claude-prow` secret. Teams using this secret just need to set two env vars in their workflow — no additional credential setup required:

```yaml
REVIEW_AGENT_AUTH_MODE: "pat"
REVIEW_AGENT_FORK_ORG: "jira-solve-bot"
```

The PAT automatically handles fork creation, branch push, and PR operations against any public `openshift/` repo. The fork is created on demand in the `jira-solve-bot` account if it doesn't already exist.

#### GitHub App Mode (Default)

If you prefer per-repo GitHub App installations, this is the default when `REVIEW_AGENT_AUTH_MODE` is not set. Requires a GitHub App installed on both your fork and upstream repos:

| Key | Description |
|---|---|
| `app-id` | GitHub App ID |
| `installation-id` | Installation ID for the **fork** repo (push access) |
| `o-h-installation-id` | Installation ID for the **upstream** repo (read PRs/comments) |
| `private-key` | GitHub App private key (PEM format) |

The app needs these permissions:
- **Fork repo**: Contents (read/write), Pull requests (read/write)
- **Upstream repo**: Pull requests (read), Issues (read)

### Vault Secret

The shared `hypershift-team-claude-prow` secret already contains both PAT and App credentials. If your team uses a different secret, create one in the `test-credentials` namespace with these keys:

**PAT mode:**

| Key | Description |
|---|---|
| `claude-prow` | GCP service account JSON for Vertex AI authentication |
| `gh-pat` | GitHub classic PAT with `public_repo` and `read:org` scopes |

**App mode:**

| Key | Description |
|---|---|
| `claude-prow` | GCP service account JSON for Vertex AI authentication |
| `app-id` | GitHub App ID |
| `installation-id` | Installation ID for fork |
| `o-h-installation-id` | Installation ID for upstream |
| `private-key` | GitHub App private key |

Mount path: `/var/run/claude-code-service-account`

### Vertex AI Access

The GCP service account needs access to the `itpc-gcp-hybrid-pe-eng-claude` project (or your configured project) for Claude API access via Vertex AI.

## Step-by-Step Setup

### 1. Create a Wrapper Workflow

Create a thin workflow YAML under your team's step-registry directory that sets the required env vars and delegates to the generic steps.

**PAT mode** (recommended):

```yaml
# ci-operator/step-registry/myteam/review-agent/myteam-review-agent-workflow.yaml
workflow:
  as: myteam-review-agent
  steps:
    pre:
      - ref: jira-agent-github-app-auth
      - ref: review-agent-setup
    test:
      - ref: review-agent-process
    post:
      - ref: review-agent-report
    env:
      REVIEW_AGENT_AUTH_MODE: "pat"
      REVIEW_AGENT_FORK_ORG: "jira-solve-bot"
      REVIEW_AGENT_UPSTREAM_REPO: "openshift/myrepo"
  documentation: |-
    MyTeam-specific wrapper for the generic review-agent workflow.
    Uses PAT auth mode — the agent auto-forks the upstream repo
    into the bot user's account if needed.
```

**App mode:**

```yaml
workflow:
  as: myteam-review-agent
  steps:
    pre:
      - ref: jira-agent-github-app-auth
      - ref: review-agent-setup
    test:
      - ref: review-agent-process
    post:
      - ref: review-agent-report
    env:
      REVIEW_AGENT_FORK_REPO: "https://github.com/myorg/myrepo"
      REVIEW_AGENT_UPSTREAM_REPO: "openshift/myrepo"
  documentation: |-
    MyTeam-specific wrapper for the generic review-agent workflow.
```

### 2. Handle Credentials

If your team uses a **different** Vault secret name than `hypershift-team-claude-prow`, you'll need to create your own ref YAMLs that point to the generic commands scripts but declare your team's credentials. Create thin ref YAMLs under your team's step-registry directory:

```yaml
# myteam/review-agent/setup/myteam-review-agent-setup-ref.yaml
ref:
  as: myteam-review-agent-setup
  from: claude-ai-helpers
  commands: review-agent-setup-commands.sh  # reuses generic commands
  # ... same env vars as review-agent-setup ...
  credentials:
  - namespace: test-credentials
    name: myteam-claude-prow  # your team's secret
    mount_path: /var/run/claude-code-service-account
```

Then reference `myteam-review-agent-setup` instead of `review-agent-setup` in your workflow.

### 3. Add CI Job Configuration

Add a periodic or presubmit job to your CI config in `ci-operator/config/<org>/<repo>/`:

**Periodic job** (daily automated processing):

```yaml
- as: periodic-review-agent
  cron: 0 10 * * *  # Daily at 10:00 AM UTC
  steps:
    workflow: myteam-review-agent
```

**Presubmit job** (on-demand via `/test` comment):

Running the review agent inline as a presubmit will abort when the agent pushes to the PR branch. Instead, use a trigger step that fires the periodic job via Gangway:

```yaml
- always_run: false
  as: address-review-comments
  optional: true
  skip_if_only_changed: .*
  steps:
    workflow: myteam-review-agent-trigger
```

See the HyperShift trigger step in `ci-operator/step-registry/hypershift/review-agent/trigger/` for a reference implementation. Your trigger workflow should call the Gangway API to launch the periodic job with the PR number as a parameter override.

### 4. Run `make update`

```bash
make update
```

This generates the Prow job configs and validates the step registry.

## Environment Variable Reference

### Required (set by wrapper workflow)

| Variable | Example | Purpose |
|---|---|---|
| `REVIEW_AGENT_UPSTREAM_REPO` | `openshift/hypershift` | Upstream `owner/repo` for `gh pr` operations |

### Auth mode configuration

| Variable | Default | Purpose |
|---|---|---|
| `REVIEW_AGENT_AUTH_MODE` | `app` | `"app"` (GitHub App) or `"pat"` (classic PAT) |
| `REVIEW_AGENT_FORK_ORG` | (none) | GitHub user/org to fork into (PAT mode only) |
| `REVIEW_AGENT_PAT_KEY` | `gh-pat` | Key name in secret for the PAT (PAT mode only) |
| `REVIEW_AGENT_FORK_REPO` | (none) | Fork repo URL (required in App mode, auto-derived in PAT mode) |

### Optional (override in CI config)

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_MODEL` | `claude-opus-4-6` | Claude model for processing |
| `REVIEW_AGENT_TARGET_PR` | (none) | Explicit PR number to process |
| `MULTISTAGE_PARAM_OVERRIDE_REVIEW_AGENT_TARGET_PR` | (none) | Gangway API override for target PR |

### Derived (computed automatically)

| Value | Derived From | Example |
|---|---|---|
| Clone directory | `basename $REVIEW_AGENT_FORK_REPO` | `/tmp/hypershift` |
| Fork repo (PAT mode) | `REVIEW_AGENT_FORK_ORG` + upstream repo name | `jira-solve-bot/hypershift` |
| System prompt context | Both env vars | "PR in openshift/hypershift from hypershift fork" |
| Telemetry `repo` field | `REVIEW_AGENT_UPSTREAM_REPO` | `openshift/hypershift` |
| Report PR links | `REVIEW_AGENT_UPSTREAM_REPO` | `github.com/openshift/hypershift/pull/123` |

## Optional: Trigger Step

For on-demand Gangway invocation (triggering the periodic job from a PR comment instead of running inline), see the HyperShift trigger step pattern in `ci-operator/step-registry/hypershift/review-agent/trigger/`. This avoids the presubmit aborting when the agent pushes to the PR branch.

## Example: Complete Workflow for `openshift/example-operator`

**PAT mode:**

```yaml
# ci-operator/step-registry/example-operator/review-agent/example-operator-review-agent-workflow.yaml
workflow:
  as: example-operator-review-agent
  steps:
    pre:
      - ref: jira-agent-github-app-auth
      - ref: review-agent-setup
    test:
      - ref: review-agent-process
    post:
      - ref: review-agent-report
    env:
      REVIEW_AGENT_AUTH_MODE: "pat"
      REVIEW_AGENT_FORK_ORG: "jira-solve-bot"
      REVIEW_AGENT_UPSTREAM_REPO: "openshift/example-operator"
  documentation: |-
    Example Operator wrapper for the generic review-agent workflow.
    Uses PAT mode for auto-fork and PR operations.
```

```yaml
# ci-operator/config/openshift/example-operator/openshift-example-operator-main.yaml (test entry)
- as: periodic-review-agent
  cron: 0 11 * * *
  steps:
    workflow: example-operator-review-agent
```

## Telemetry

All review-agent runs write telemetry to the shared `address_review_agent` BigQuery table. The `repo` field is automatically populated from `REVIEW_AGENT_UPSTREAM_REPO`, allowing per-team filtering.
