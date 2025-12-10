#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_TOKEN="$(</var/run/bugwatcher/jira-token)"
SLACK_HOOK="$(</var/run/slack-hooks/forum-shiftstack)"
PEOPLE="$(</var/run/team/people.yaml)"

export JIRA_TOKEN
export SLACK_HOOK
export PEOPLE

exec /bin/pretriage
