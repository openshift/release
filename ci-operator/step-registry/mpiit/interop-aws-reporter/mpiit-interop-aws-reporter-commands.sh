#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -o verbose

export $SLACK_WEBHOOK_URL
trap "sleep 30m" EXIT TERM INT SIGINT ERR

RUN_COMMAND="poetry run python interop_aws_reporter/app.py"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}