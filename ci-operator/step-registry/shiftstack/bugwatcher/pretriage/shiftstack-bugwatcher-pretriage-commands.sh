#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_TOKEN="$(<var/run/bugwatcher/jira-token)"
BUGZILLA_API_KEY="$(</var/run/bugwatcher/bugzilla-api-key)"
SLACK_HOOK="$(</var/run/slack-hooks/forum-shiftstack)"
TEAM_MEMBERS="$(</var/run/team/team.json)"

export BUGZILLA_API_KEY
export SLACK_HOOK
export TEAM_MEMBERS
export JIRA_TOKEN

case "$TICKETING_SYSTEM" in
	bugzilla) echo 'Running against Bugzilla.'; exec ./pretriage.py ;;
	jira)     echo 'Running against Jira.';     exec /bin/pretriage ;;
	*) echo "Unknown value for TICKETING_SYSTEM: '$TICKETING_SYSTEM'"; exit 1 ;;
esac
