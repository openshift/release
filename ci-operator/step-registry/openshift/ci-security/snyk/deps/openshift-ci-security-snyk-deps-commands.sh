#!/bin/sh

SNYK_TOKEN="$(cat $SNYK_TOKEN_PATH)"
export SNYK_TOKEN

curl https://static.snyk.io/cli/latest/snyk-linux -o /tmp/snyk && \
    chmod +x /tmp/snyk

echo Starting snyk dependencies scan
/tmp/snyk test --project-name="$PROJECT_NAME" --org="$ORG_NAME"
