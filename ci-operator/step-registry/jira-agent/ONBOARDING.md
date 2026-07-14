# Jira Agent Onboarding Guide

This guide walks you through setting up the **jira-agent** periodic Prow job for your OpenShift team. The jira-agent automatically picks up Jira issues, solves them using Claude Code, runs code review, addresses findings, creates PRs, and sends Slack notifications.

## How It Works

The jira-agent runs as a periodic Prow job that:

1. **Setup** — Verifies Claude Code CLI and Vertex AI credentials
2. **Process** — For each Jira issue matching your JQL query:
   - Phase 1: Runs `/jira:solve` to analyze and fix the issue
   - Phase 2: Runs pre-commit code review
   - Phase 3: Addresses review findings
   - Phase 4: Creates a PR to your upstream repo
   - Labels the Jira issue, transitions status, sets assignee, sends Slack notification
3. **Report** — Generates an HTML report with token usage, cost breakdown, and phase output

Your team creates a **thin workflow YAML** that sets team-specific env vars and references the generic step registry components. No bash scripting required.

## Prerequisites

Before starting, you need:

- [ ] **A GitHub App** installed on both your fork org and upstream repo (for push and PR creation)
- [ ] **A fork organization** on GitHub where the agent pushes branches (see below)
- [ ] **Vault secret** synced to OpenShift CI with your credentials (see [Credentials Setup](#credentials-setup))
- [ ] **Vertex AI access** via a Google Cloud service account (for Claude Code)
- [ ] **Jira labels** on issues you want the agent to process (e.g., `issue-for-agent`)
- [ ] **(Optional)** Slack incoming webhook for PR notifications

### Fork / Upstream Model

The jira-agent pushes branches to a **fork** and creates PRs against the **upstream** repo.
This is the same fork-based workflow developers use — it avoids needing write access to the upstream repo.

**Example:** For the HyperShift team:
- **Upstream** (`JIRA_AGENT_UPSTREAM_REPO`): `openshift/hypershift` — where PRs are created against
- **Fork** (`JIRA_AGENT_FORK_REPO`): `hypershift-community/hypershift` — where the agent pushes branches

For teams working on repos within the `openshift/` GitHub org, you'll typically create a fork organization
(e.g., `my-team-bots/my-repo`) and install the GitHub App on both. The agent only needs push access to the
fork; PR creation to the upstream repo is handled by the GitHub App's permissions.

## Step 1: Create Your Workflow YAML

Create a workflow file in `openshift/release` at:
```
ci-operator/step-registry/<your-team>/jira-agent/<your-team>-jira-agent-workflow.yaml
```

Here's a template — replace the values with your team's configuration:

```yaml
workflow:
  as: <your-team>-jira-agent
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
      # Required: your fork and upstream repos
      JIRA_AGENT_FORK_REPO: "<your-org>/<your-repo>"
      JIRA_AGENT_UPSTREAM_REPO: "openshift/<your-repo>"

      # Required: JQL query to find issues for the agent
      JIRA_AGENT_JQL: 'project = OCPBUGS AND resolution = Unresolved AND status in (New, "To Do") AND labels = issue-for-agent AND labels != agent-processed'

      # Optional: transition issues to a status after processing
      JIRA_AGENT_TARGET_STATUS: '{"OCPBUGS":"ASSIGNED"}'

      # Optional: set assignee on processed issues
      JIRA_AGENT_ASSIGNEE: "my-team-automation"

      # Optional: credential key names in your Vault secret
      JIRA_AGENT_UPSTREAM_INSTALLATION_ID_KEY: "upstream-installation-id"
      JIRA_AGENT_FORK_INSTALLATION_ID_KEY: "fork-installation-id"

      # Optional: project-specific tool/plugin setup (runs before processing)
      JIRA_AGENT_TOOL_SETUP_SCRIPT: "GOFLAGS='' go install golang.org/x/tools/gopls@latest"

      # Optional: code review configuration
      JIRA_AGENT_REVIEW_LANGUAGE: "go"
      JIRA_AGENT_REVIEW_PROFILE: ""

      # Optional: Slack notification emoji
      JIRA_AGENT_SLACK_EMOJI: ":robot:"

  documentation: |-
    <Your-Team>-specific wrapper for the generic Jira Agent workflow.
    Credentials: Uses <your-secret-name> (configured in generic step refs).
```

## Step 2: Create the Periodic Job Config

Create a CI config file in `openshift/release` at:
```
ci-operator/config/openshift/<your-repo>/openshift-<your-repo>-main__periodics.yaml
```

Example:

```yaml
base_images:
  cli:
    name: "4.18"
    namespace: ocp
    tag: cli
build_root:
  image_stream_tag:
    name: release
    namespace: openshift
    tag: golang-1.23
tests:
- as: periodic-jira-agent
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: hypershift
    product: ocp
    timeout: 2h0m0s
    version: "4.18"
  cron: 0 */4 * * 1-5
  steps:
    workflow: <your-team>-jira-agent
zz_generated_metadata:
  branch: main
  org: openshift
  repo: <your-repo>
  variant: periodics
```

After creating these files, run:
```bash
make update
```

## Credentials Setup

The jira-agent reads credentials from `/var/run/claude-code-service-account/`. Your Vault secret must contain these keys:

| Key | Description |
|-----|-------------|
| `app-id` | GitHub App ID |
| `private-key` | GitHub App private key (PEM format) |
| `<fork-installation-id-key>` | Installation ID for your fork org (default key: `installation-id`) |
| `<upstream-installation-id-key>` | Installation ID for upstream repo (default key: `o-h-installation-id`) |
| `jira-email` | Jira account email for API access |
| `jira-pat` | Jira API token (personal access token) |
| `slack-webhook-url` | **(Optional)** Slack incoming webhook URL |
| `gh-to-slack-ids` | **(Optional)** JSON mapping of GitHub usernames to Slack user IDs |

### GitHub App Setup

1. Create a GitHub App at https://github.com/settings/apps
2. Grant permissions: `Contents: Read & write`, `Pull requests: Read & write`, `Metadata: Read-only`
3. Install the app on your fork organization and your upstream repository
4. Note the installation IDs for each (visible in the app settings URL after installation)
5. Download the private key

### Vault Secret

Store your credentials in Vault under a collection accessible by OpenShift CI. The generic step registry refs declare the secret mount; your workflow overrides the secret name.

See [OpenShift CI Secret Management](https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/) for details on syncing secrets to CI.

### GitHub-to-Slack Mapping

The `gh-to-slack-ids` file is a JSON object mapping GitHub usernames to Slack member IDs. Include a `backup-user` key for fallback when no reviewers are assigned:

```json
{
  "github-user-1": "U01ABCDEF",
  "github-user-2": "U02GHIJKL",
  "backup-user": "U03MNOPQR"
}
```

Find Slack member IDs by viewing a user's profile in Slack and clicking "Copy member ID".

## Environment Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `JIRA_AGENT_FORK_REPO` | Yes | — | Fork repo slug (e.g., `my-org/my-repo`) |
| `JIRA_AGENT_UPSTREAM_REPO` | Yes | — | Upstream repo slug (e.g., `openshift/my-repo`) |
| `JIRA_AGENT_JQL` | Yes* | — | JQL query for finding issues (*not required if `JIRA_AGENT_ISSUE_KEY` is set) |
| `JIRA_AGENT_ISSUE_KEY` | No | — | Process a specific issue instead of running JQL |
| `JIRA_AGENT_TARGET_STATUS` | No | `""` | JSON map of project prefix to target status |
| `JIRA_AGENT_ASSIGNEE` | No | `""` | Display name to search when setting assignee |
| `JIRA_AGENT_UPSTREAM_INSTALLATION_ID_KEY` | No | `o-h-installation-id` | Key name in secret for upstream GitHub App installation ID |
| `JIRA_AGENT_FORK_INSTALLATION_ID_KEY` | No | `installation-id` | Key name in secret for fork GitHub App installation ID |
| `JIRA_AGENT_TOOL_SETUP_SCRIPT` | No | `""` | Shell commands to install project-specific tools or plugins |
| `JIRA_AGENT_REVIEW_LANGUAGE` | No | `go` | Language for the code-review plugin |
| `JIRA_AGENT_REVIEW_PROFILE` | No | `""` | Profile for the code-review plugin |
| `JIRA_AGENT_SLACK_EMOJI` | No | `:robot:` | Slack message emoji prefix |
| `JIRA_AGENT_MAX_ISSUES` | No | `1` | Maximum issues to process per run |
| `CLAUDE_MODEL` | No | `claude-opus-4-6` | Claude model to use |
| `JIRA_BASE_URL` | No | `https://redhat.atlassian.net` | Jira instance base URL |

## Jira Setup

### Labels

The agent uses labels to track which issues have been processed:

- **`issue-for-agent`** — Add this label to issues you want the agent to pick up
- **`agent-processed`** — The agent adds this label after processing (prevents re-processing)

Your JQL query should include `labels = issue-for-agent AND labels != agent-processed` to implement this pattern.

### Security Level

Make sure your Jira issues are accessible to the service account. If issues have restricted security levels, the agent's API token must have access to that level. Issues with security levels the agent can't see will silently be excluded from JQL results.

## Troubleshooting

### "No issues found"

- Check that your JQL query returns results in the Jira UI
- Verify the Jira API token has access to the project and security level
- Ensure issues have the `issue-for-agent` label (or whatever your JQL filters for)

### "Required credentials are missing"

- Verify your Vault secret is synced to the CI namespace
- Check that the key names in your secret match `JIRA_AGENT_FORK_INSTALLATION_ID_KEY` and `JIRA_AGENT_UPSTREAM_INSTALLATION_ID_KEY`
- Required keys: `app-id`, `private-key`, fork installation ID, upstream installation ID

### "Failed to generate GitHub App token"

- Verify the GitHub App is installed on the target org/repo
- Check that the installation ID is correct (not the app ID)
- Ensure the private key matches the app

### Plugin installation fails

- The process script forces HTTPS for git operations (`git config --global url."https://github.com/".insteadOf "git@github.com:"`)
- If you see SSH-related errors, check that this config is applied before plugin installs

### PR creation fails

- Verify the GitHub App has `Pull requests: Read & write` permission on the upstream repo
- Check that the fork is synced with upstream (the agent does this automatically)
- Ensure the branch name doesn't conflict with an existing branch

### Rehearsal Testing

To test your job in a PR to `openshift/release`, trigger a rehearsal with the full job name:

```
/pj-rehearse periodic-ci-openshift-<your-repo>-main-periodic-jira-agent
```

Never run bare `/pj-rehearse` — always specify the full job name.

## Example: HyperShift Configuration

For a working example, see the HyperShift jira-agent workflow:
- Workflow YAML: `ci-operator/step-registry/hypershift/jira-agent/hypershift-jira-agent-workflow.yaml`
- Periodic config: `ci-operator/config/openshift/hypershift/openshift-hypershift-main__periodics.yaml`
