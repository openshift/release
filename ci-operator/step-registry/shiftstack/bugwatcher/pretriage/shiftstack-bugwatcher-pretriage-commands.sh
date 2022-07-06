#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_TOKEN="$(</var/run/bugwatcher/jira-token)"
SLACK_HOOK="$(</var/run/slack-hooks/forum-shiftstack)"
TEAM_MEMBERS="$(</var/run/team/team.json)"

export JIRA_TOKEN
export SLACK_HOOK
export TEAM_MEMBERS

exec /bin/pretriage
