#!/bin/bash

set -o nounset
set -o pipefail

WEBHOOK_URL="$(cat /var/run/vault/osac-slack-webhook/url)"
PROW_URL="https://prow.ci.openshift.org/view/gs/test-platform-results"

if [[ "${JOB_TYPE:-}" == "presubmit" ]]; then
    JOB_URL="${PROW_URL}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    JOB_URL="${PROW_URL}/logs/${JOB_NAME}/${BUILD_ID}"
fi

curl -s -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"Job *${JOB_NAME}* #${BUILD_ID} completed.\n<${JOB_URL}|View logs>\"}" \
    "${WEBHOOK_URL}"
