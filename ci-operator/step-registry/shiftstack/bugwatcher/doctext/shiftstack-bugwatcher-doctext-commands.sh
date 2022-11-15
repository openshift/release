#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_TOKEN="$(</var/run/bugwatcher/jira-token)"
SLACK_HOOK="$(</var/run/slack-hooks/forum-shiftstack)"
TEAM_MEMBERS_DICT="$(</var/run/team/teamdict.json)"
TEAM_VACATION="$(</var/run/team/vacation.json)"

export JIRA_TOKEN
export SLACK_HOOK
export TEAM_MEMBERS_DICT
export TEAM_VACATION

exec /bin/doctext
