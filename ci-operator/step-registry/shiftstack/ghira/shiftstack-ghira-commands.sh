#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_ACCOUNT_ID="$(</var/run/ghira/jira-account-id)"
JIRA_EMAIL="$(</var/run/ghira/jira-email)"
JIRA_TOKEN="$(</var/run/ghira/jira-token)"
GITHUB_TOKEN="$(</var/run/ghira/github-token)"
PEOPLE="$(</var/run/team/people.yaml)"

export JIRA_ACCOUNT_ID
export JIRA_EMAIL
export JIRA_TOKEN
export GITHUB_TOKEN
export PEOPLE

exec /bin/ghira
