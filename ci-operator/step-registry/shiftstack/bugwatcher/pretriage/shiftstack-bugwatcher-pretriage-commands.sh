#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_ACCOUNT_ID="$(</var/run/bugwatcher/jira-account-id)"
JIRA_EMAIL="$(</var/run/bugwatcher/jira-email)"
JIRA_TOKEN="$(</var/run/bugwatcher/jira-token)"
SLACK_HOOK="$(</var/run/slack-hooks/forum-shiftstack)"
PEOPLE="$(</var/run/team/people.yaml)"

export JIRA_ACCOUNT_ID
export JIRA_EMAIL
export JIRA_TOKEN
export SLACK_HOOK
export PEOPLE

exec /bin/pretriage
