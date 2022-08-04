#!/usr/bin/env bash

set -Eeuo pipefail

BUGZILLA_API_KEY="$(</var/run/bugwatcher/bugzilla-api-key)"
SLACK_HOOK="$(</var/run/slack-hooks/forum-shiftstack)"
TEAM_MEMBERS_DICT="$(</var/run/team/teamdict.json)"
TEAM_VACATION="$(</var/run/team/vacation.json)"

export BUGZILLA_API_KEY
export SLACK_HOOK
export TEAM_MEMBERS_DICT
export TEAM_VACATION

exec ./doctext.py
