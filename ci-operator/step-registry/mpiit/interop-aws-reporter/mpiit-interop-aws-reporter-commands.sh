#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap "sleep 30m" EXIT TERM INT SIGINT ERR
export SLACK_WEBHOOK_URL=$(cat /tmp/secrets/slack-webhook-url.json)
export CLEANUP_AWS__AUTH__ACCESS_KEY=$(cat /tmp/secrets/aws-access-key.json)
export CLEANUP_AWS__AUTH__SECRET_KEY=$(cat /tmp/secrets/aws-secret-key.json)

export CLEANUP_AWS__AUTH__REGIONS='["all"]'
export CLEANUP_AWS__CRITERIA__OCPS__OCP_CLIENT_REGION=$AWS_CLIENT_REGION
export CLEANUP_AWS__CRITERIA__OCPS__SLA=$CLEANUP_SLA

RUN_COMMAND="poetry run python interop_aws_reporter/app.py"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}