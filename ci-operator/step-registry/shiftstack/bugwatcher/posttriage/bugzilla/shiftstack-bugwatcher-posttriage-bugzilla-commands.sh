#!/usr/bin/env bash

set -Eeuo pipefail

BUGZILLA_API_KEY="$(</var/run/bugwatcher/bugzilla-api-key)"

export BUGZILLA_API_KEY

exec ./posttriage.py
