# jira-agent Step Registry

Generic, reusable Jira Agent workflow for automated issue processing using Claude Code.

## Overview

This step registry provides a parameterized workflow that automatically picks up Jira issues,
solves them using Claude Code, runs code review, addresses findings, creates PRs, and sends
Slack notifications.

All teams share one generic `jira-agent` workflow **and one central Prow job** —
`periodic-ci-openshift-release-main-jira-agent-periodic-jira-agent`, defined in
[`../../config/openshift/release/openshift-release-main__jira-agent.yaml`](../../config/openshift/release/openshift-release-main__jira-agent.yaml).
That job runs with `JIRA_AGENT_TEAM: all`: the team-config step builds one independently
limited Jira query per team and a component→repo map from the single **team table**
([`team-config/jira-agent-team-config-commands.sh`](team-config/jira-agent-team-config-commands.sh)),
and the process step discovers each issue's repo from its Jira component (falling back to its
project). The same job is what chai/Gangway triggers for one ticket via an issue-key override.

There is **no per-team Prow job** — onboarding is a single `case` arm in the team table.

## Quick Start

1. Add a `case` arm for your team to `configure_team` in
   `team-config/jira-agent-team-config-commands.sh`, and add your team id to the `TEAMS` list at
   the top of that file. Set only the variables you need; anything you omit uses the documented
   default. For the central job the key fields are your repo, its routing component(s)/project(s),
   and your JQL:

   ```bash
   my-team)
     export JIRA_AGENT_UPSTREAM_REPO="openshift/my-repo"
     export JIRA_AGENT_COMPONENTS="My Component"     # routes issues to your repo
     # export JIRA_AGENT_PROJECTS="MYPROJ"           # only if routed by project key
     export JIRA_AGENT_JQL='project = OCPBUGS AND resolution = Unresolved AND status in (New, "To Do") AND component = "My Component" AND labels = issue-for-agent AND labels != agent-processed'
     export JIRA_AGENT_MAX_ISSUES="1"                # this team's scheduled-run limit
     export JIRA_AGENT_SLACK_EMOJI=":robot:"
     ;;
   ```

   Auth, fork org, and tool setup are uniform in the central job, so you don't set them here.

2. Run `make update` and open a PR. The central all-teams job picks up your arm automatically —
   no new job to create.

For working examples, see the `hypershift`, `installer`, `windows`, `mco`, and `ingress` arms in the team table.
See [ONBOARDING.md](ONBOARDING.md) for the full field reference, repo-routing details, credentials
setup, and troubleshooting.
