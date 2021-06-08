#!/usr/bin/env bash

set -Eeuo pipefail

BUGZILLA_API_KEY="$(</var/run/bugzilla/api-key)"
SLACK_HOOK="$(</var/run/slack/hook_forum-shiftstack)"
TEAM_MEMBERS="$(</var/run/team/team.json)"

export BUGZILLA_API_KEY
export SLACK_HOOK
export TEAM_MEMBERS

python ./main.py
