#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap "sleep 30m" EXIT TERM INT SIGINT ERR
SLACK_WEBHOOK_URL=$(cat /tmp/secrets/slack-webhook-url.json)
export SLACK_WEBHOOK_URL

RUN_COMMAND="poetry run python interop_aws_reporter/app.py"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}