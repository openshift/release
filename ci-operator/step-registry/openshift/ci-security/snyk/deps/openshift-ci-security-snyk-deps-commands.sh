#!/bin/sh

SNYK_TOKEN="$(cat $SNYK_TOKEN_PATH)"
export SNYK_TOKEN

curl https://static.snyk.io/cli/latest/snyk-linux -o /tmp/snyk && \
    chmod +x /tmp/snyk

echo Starting snyk dependencies scan
# if ALL_PROJECT is true
if [ "$ALL_PROJECTS" = "true" ]; then
    /tmp/snyk test --project-name="$PROJECT_NAME" --org="$ORG_NAME" --all-projects
else
    /tmp/snyk test --project-name="$PROJECT_NAME" --org="$ORG_NAME"
fi
