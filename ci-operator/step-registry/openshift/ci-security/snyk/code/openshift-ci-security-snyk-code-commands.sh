#!/bin/sh

SNYK_TOKEN="$(cat $SNYK_TOKEN_PATH)"
export SNYK_TOKEN

curl https://static.snyk.io/cli/latest/snyk-linux -o /tmp/snyk && \
    chmod +x /tmp/snyk

echo Starting snyk code scan
/tmp/snyk code test --project-name="$PROJECT_NAME" --org="$ORG_NAME" --sarif-file-output=${ARTIFACT_DIR}/snyk.sarif.json --report
echo Full vulnerabilities report is available at ${ARTIFACT_DIR}/snyk.sarif.json
