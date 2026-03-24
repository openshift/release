#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_ACCOUNT_ID="$(</var/run/bugwatcher/jira-account-id)"
JIRA_EMAIL="$(</var/run/bugwatcher/jira-email)"
JIRA_TOKEN="$(</var/run/bugwatcher/jira-token)"

export JIRA_ACCOUNT_ID
export JIRA_EMAIL
export JIRA_TOKEN

exec /bin/posttriage
