#!/usr/bin/env bash

set -Eeuo pipefail

BUGZILLA_API_KEY="$(</var/run/bugzilla/api-key)"
export BUGZILLA_API_KEY

./posttriage.py
