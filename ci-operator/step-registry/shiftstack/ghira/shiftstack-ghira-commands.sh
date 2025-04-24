#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_TOKEN="$(</var/run/bugwatcher/jira-token)"
GITHUB_TOKEN="$(</var/run/ghira/github-token)"
TEAM_DICT="$(</var/run/team/teamdict.json)"

export JIRA_TOKEN
export GITHUB_TOKEN
export TEAM_DICT

exec /bin/ghira
