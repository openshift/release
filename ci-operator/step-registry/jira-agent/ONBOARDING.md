# Jira Agent Onboarding Guide

This guide walks you through onboarding your OpenShift team to the **jira-agent**. The jira-agent automatically picks up Jira issues, solves them using Claude Code, runs code review, addresses findings, creates PRs, and sends Slack notifications.

There is **one central jira-agent job** that serves every team — you do **not** create a per-team Prow job. Onboarding is a single `case` arm in the team-config step; the central job discovers the right repo for each issue from its Jira component.

## How It Works

A single central periodic Prow job —
`periodic-ci-openshift-release-main-jira-agent-periodic-jira-agent`, defined in
`ci-operator/config/openshift/release/openshift-release-main__jira-agent.yaml` —
runs the generic `jira-agent` workflow with `JIRA_AGENT_TEAM: all`. It:

1. **Team config (aggregate)** — Builds an independently limited Jira query for each team and per-component maps (repo, review profile, Slack emoji, assignee) from the team table.
2. **Setup** — Verifies Claude Code CLI and Vertex AI credentials.
3. **Process** — Runs each team's query up to that team's `JIRA_AGENT_MAX_ISSUES`, deduplicates the results, and for each selected issue:
   - Discovers the upstream repo from the issue's Jira **component** (falling back to its **project** key), then clones/forks/syncs that repo.
   - Phase 1: Runs `/openshift-developer:jira-solve` to analyze and fix the issue
   - Phase 2: Runs pre-commit code review
   - Phase 3: Addresses review findings
   - Phase 4: Creates a PR to the upstream repo
   - Labels the Jira issue, transitions status, sets assignee, sends Slack notification
4. **Report** — Generates an HTML report with token usage, cost breakdown, and phase output

The same job is what **chai/Gangway** triggers for a single ticket: it passes an
issue-key override (`MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY`), and the repo
is still discovered from that issue's component. Because the job uses one uniform
setup for every repo, it authenticates with a **classic PAT** and auto-forks into
the `jira-solve-bot` org, and installs a **superset tool setup** (gopls + pre-commit)
once before processing.

Onboarding a team is a single `case` arm in the team table (the team-config step) —
no per-team periodic, no per-team GitHub App, and no wrapper workflow are required.

## Prerequisites

Because the central job uses one uniform auth mode (a shared PAT that auto-forks into
`jira-solve-bot`), onboarding a team needs very little:

- [ ] **Your upstream repo** (e.g., `openshift/my-repo`) — the `jira-solve-bot` bot account must be able to fork it and open PRs against it.
- [ ] **The Jira component name** your issues use (e.g., `My Component`) — this is how the job routes an issue to your repo. If your issues live in a dedicated Jira project instead, note the **project key** (e.g., `WINC`).
- [ ] **Jira labels** on issues you want the agent to process (e.g., `issue-for-agent`).
- [ ] **(Optional)** Slack incoming webhook for PR notifications, and a per-team emoji.

The shared credentials (GitHub PAT, Vertex AI service account, Jira API token, Slack
webhook) are already synced to CI for the central job — see [Credentials Setup](#credentials-setup).
You do **not** need to create a per-team GitHub App or fork organization.

### Repo Routing (component → repo)

The central job discovers which repo an issue belongs to from the issue itself:

1. **Component** — `JIRA_AGENT_COMPONENTS` in your `case` arm maps your Jira component name(s) to your `JIRA_AGENT_UPSTREAM_REPO`.
2. **Project (fallback)** — `JIRA_AGENT_PROJECTS` maps a whole Jira project key to your repo, for teams whose issues are routed by project and may not carry a component (e.g., `WINC`).

The agent pushes branches to a **fork** in `jira-solve-bot` and opens PRs against your
upstream repo — the same fork-based workflow developers use, so no write access to the
upstream repo is needed.

> **Advanced / targeted runs:** the team table also supports a per-team GitHub App
> (`JIRA_AGENT_AUTH_MODE=app` with `JIRA_AGENT_FORK_REPO` and installation-id keys). The
> central all-teams job ignores those and always uses the uniform PAT + `jira-solve-bot`
> fork; per-team auth only takes effect for a targeted single-team run
> (`JIRA_AGENT_TEAM=<your-team>`, e.g. triggered ad hoc via Gangway).

## Step 1: Add Your Team to the Team Table

All team configuration lives in one place — the team table (`configure_team`) in:

```text
ci-operator/step-registry/jira-agent/team-config/jira-agent-team-config-commands.sh
```

Add a `case` arm keyed by your team id, and add your team id to the `TEAMS` list at the
top of the file so the central all-teams job includes you. Set only the variables your
team needs; anything you omit falls back to the documented default (see the
[Environment Variable Reference](#environment-variable-reference)).

For the central all-teams job, the fields that matter are your **repo**, the
**component(s)/project(s)** that route issues to it, and your **JQL**. Auth, fork org,
and tool setup are uniform across the job, so you don't set them here.

```bash
  my-team)
    export JIRA_AGENT_UPSTREAM_REPO="openshift/my-repo"
    # How the job routes an issue to your repo:
    export JIRA_AGENT_COMPONENTS="My Component"          # newline-separated for multiple
    # export JIRA_AGENT_PROJECTS="MYPROJ"                # only if routed by project key
    export JIRA_AGENT_JQL='project = OCPBUGS AND resolution = Unresolved AND status in (New, "To Do") AND component = "My Component" AND labels = issue-for-agent AND labels != agent-processed'
    export JIRA_AGENT_MAX_ISSUES="1"                     # limit for this team per scheduled run
    # Optional:
    export JIRA_AGENT_TARGET_STATUS='{"OCPBUGS":"ASSIGNED"}'   # per-project target status
    export JIRA_AGENT_ASSIGNEE="my-team-automation"            # Jira display name to assign
    export JIRA_AGENT_REVIEW_PROFILE="my-profile"             # code-review plugin profile
    export JIRA_AGENT_SLACK_EMOJI=":robot:"                    # notification emoji
    ;;
```

Notes:

- **Independent limits** — each team's JQL runs separately with that team's
  `JIRA_AGENT_MAX_ISSUES`. A value of `1` means the central periodic can select one issue for
  this team in addition to the independently selected issues from other teams.
- **JQL isolation** — put every condition your team needs (e.g., an extra
  `labels = ready-to-solve`) inside your own `JIRA_AGENT_JQL`. Teams do not share label
  requirements.
- **Multiple components** — set `JIRA_AGENT_COMPONENTS` to a newline-separated list.
- **Project routing** — set `JIRA_AGENT_PROJECTS` when issues may not carry your component
  (the job falls back to the issue key's project prefix, e.g. `WINC-9` → `WINC`).
- **Extra tools** — the central job installs a uniform superset (gopls + pre-commit). If your
  repo needs additional tooling, extend the superset in `build_aggregate` (in the same file);
  a per-team `JIRA_AGENT_TOOL_SETUP_SCRIPT` only applies to targeted single-team runs.
- **Non-`main` default branch** — set `export JIRA_AGENT_DEFAULT_BRANCH="master"` (see the `windows` arm).

## Step 2: Regenerate and You're Done

There is **no per-team Prow job to create** — the central job already runs for all teams.
After editing the team table, regenerate metadata:

```bash
make update
```

This refreshes the step-registry metadata. Your team is now included in the central
job's per-team query plan and component→repo map. To try it before merging, rehearse
the central job (see [Rehearsal Testing](#rehearsal-testing)).

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
| `<slack-webhook-key>` | **(Optional)** Slack incoming webhook URL (default key: `slack-webhook-url`; override per team with `JIRA_AGENT_SLACK_WEBHOOK_KEY`) |
| `gh-to-slack-ids` | **(Optional)** JSON mapping of GitHub usernames to Slack user IDs |

### GitHub App Setup

1. Create a GitHub App at https://github.com/settings/apps
2. Grant permissions: `Contents: Read & write`, `Pull requests: Read & write`, `Metadata: Read-only`
3. Install the app on your fork organization and your upstream repository
4. Note the installation IDs for each (visible in the app settings URL after installation)
5. Download the private key

### Vault Secret

Store your credentials in Vault under a collection accessible by OpenShift CI. The generic step registry refs declare the secret mount.

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

These are the `JIRA_AGENT_*` variables you set in your team's `case` arm. Required variables must be
set for every team; optional variables fall back to the listed default.

> In the **central all-teams job**, auth and setup are uniform: `JIRA_AGENT_AUTH_MODE`,
> `JIRA_AGENT_FORK_ORG`, `JIRA_AGENT_FORK_REPO`, the `*_INSTALLATION_ID_KEY` keys, and
> `JIRA_AGENT_TOOL_SETUP_SCRIPT` are set by aggregate mode, so per-team values for those are
> used only for a targeted single-team run (`JIRA_AGENT_TEAM=<your-team>`).

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `JIRA_AGENT_UPSTREAM_REPO` | Yes | — | Upstream repo slug (e.g., `openshift/my-repo`) |
| `JIRA_AGENT_COMPONENTS` | Yes* | — | Newline-separated Jira component name(s) that route issues to your repo in the central job (*at least one of `JIRA_AGENT_COMPONENTS`/`JIRA_AGENT_PROJECTS`) |
| `JIRA_AGENT_PROJECTS` | Yes* | — | Newline-separated Jira project key(s) that route issues to your repo when they may not carry your component (fallback by issue key prefix) |
| `JIRA_AGENT_JQL` | Yes* | — | JQL query for finding issues (*not required if `JIRA_AGENT_ISSUE_KEY` is set) |
| `JIRA_AGENT_FORK_REPO` | App mode | — | Fork repo slug (e.g., `my-org/my-repo`); required in App auth mode |
| `JIRA_AGENT_AUTH_MODE` | No | `app` | `app` (GitHub App) or `pat` (classic token + auto-fork) |
| `JIRA_AGENT_FORK_ORG` | PAT mode | — | Fork org the upstream repo is auto-forked into; required in PAT auth mode |
| `JIRA_AGENT_DEFAULT_BRANCH` | No | `main` | Upstream default branch (set `master` where applicable) |
| `JIRA_AGENT_ISSUE_KEY` | No | — | Process a specific issue instead of running JQL |
| `JIRA_AGENT_TARGET_STATUS` | No | `""` | JSON map of project prefix to target status |
| `JIRA_AGENT_ASSIGNEE` | No | `""` | Display name to search when setting assignee |
| `JIRA_AGENT_UPSTREAM_INSTALLATION_ID_KEY` | No | `o-h-installation-id` | Key name in secret for upstream GitHub App installation ID |
| `JIRA_AGENT_FORK_INSTALLATION_ID_KEY` | No | `installation-id` | Key name in secret for fork GitHub App installation ID |
| `JIRA_AGENT_TOOL_SETUP_SCRIPT` | No | `""` | Shell commands to install project-specific tools or plugins |
| `JIRA_AGENT_REVIEW_LANGUAGE` | No | `go` | Language for the code-review plugin |
| `JIRA_AGENT_REVIEW_PROFILE` | No | `""` | Profile for the code-review plugin |
| `JIRA_AGENT_SLACK_EMOJI` | No | `:robot:` | Slack message emoji prefix |
| `JIRA_AGENT_SLACK_WEBHOOK_KEY` | No | `slack-webhook-url` | Key name in the secret for the Slack webhook URL (point a team at its own channel) |
| `JIRA_AGENT_MAX_ISSUES` | No | `1` | Maximum issues selected by this team's JQL per scheduled run |
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

To test the central job in a PR to `openshift/release`, trigger a rehearsal with its full name:

```
/pj-rehearse periodic-ci-openshift-release-main-jira-agent-periodic-jira-agent
```

This runs the all-teams job (including your new arm). Never run bare `/pj-rehearse` — always specify the full job name.

## Examples

For working examples, see the existing arms in `configure_team`:
- Team table: `ci-operator/step-registry/jira-agent/team-config/jira-agent-team-config-commands.sh`
  - `hypershift` — component routing plus an extra `ready-to-solve` label and a review profile/emoji
  - `installer` — simple single-component routing
  - `windows` — component **and** project (`WINC`) routing, with a `master` default branch
  - `mco` — component **and** project (`MCO`) routing
  - `ingress` — component **and** project (`NE`) routing, with a `master` default branch
- Central job config: `ci-operator/config/openshift/release/openshift-release-main__jira-agent.yaml`
