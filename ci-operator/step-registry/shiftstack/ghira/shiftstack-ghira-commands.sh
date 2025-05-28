#!/usr/bin/env bash

set -Eeuo pipefail

JIRA_TOKEN="$(</var/run/ghira/jira-token)"
GITHUB_TOKEN="$(</var/run/ghira/github-token)"
PEOPLE="$(</var/run/team/people.yaml)"
TEAM="$(</var/run/team/team.yaml)"

export JIRA_TOKEN
export GITHUB_TOKEN
export PEOPLE
export TEAM

exec /bin/ghira
