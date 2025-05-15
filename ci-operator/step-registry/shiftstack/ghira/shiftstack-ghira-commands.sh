#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_TOKEN="$(</var/run/bugwatcher/jira-token)"
GITHUB_TOKEN="$(</var/run/ghira/github-token)"
TEAM_DICT="$(</var/run/team/teamdict.json)"
PEOPLE="$(</var/run/team/people.yaml)"
TEAM="$(</var/run/team/team.yaml)"

export JIRA_TOKEN
export GITHUB_TOKEN
export TEAM_DICT
export PEOPLE
export TEAM

exec /bin/ghira
