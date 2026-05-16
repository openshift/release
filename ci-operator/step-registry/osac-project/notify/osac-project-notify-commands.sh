#!/bin/bash

set -euo pipefail

WEBHOOK_URL="$(cat /var/run/vault/osac-slack-webhook/url)"
PROW_URL="https://prow.ci.openshift.org/view/gs/test-platform-results"

if [[ "${JOB_TYPE:-}" != "periodic" ]]; then
    echo "Skipping Slack notification for non-periodic job (type: ${JOB_TYPE:-unknown})"
    exit 0
fi

JOB_URL="${PROW_URL}/logs/${JOB_NAME}/${BUILD_ID}"

RESULT="UNKNOWN"
EMOJI=":white_circle:"
if [[ -f "${SHARED_DIR}/test-result" ]]; then
    RESULT=$(cat "${SHARED_DIR}/test-result")
fi
if [[ "${RESULT}" == "PASSED" ]]; then
    EMOJI=":large_green_circle:"
elif [[ "${RESULT}" == "FAILED" ]]; then
    EMOJI=":red_circle:"
fi

VERSIONS=""
if [[ -f "${SHARED_DIR}/versions.txt" ]]; then
    while IFS= read -r line; do
        VERSIONS="${VERSIONS}\n${line}"
    done < "${SHARED_DIR}/versions.txt"
fi

MESSAGE="${EMOJI} *${JOB_NAME}* — ${RESULT}\n<${JOB_URL}|View logs>"
if [[ -n "${VERSIONS}" ]]; then
    MESSAGE="${MESSAGE}\n\n*Versions:*\n\`\`\`${VERSIONS}\n\`\`\`"
fi

curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"${MESSAGE}\"}" \
    "${WEBHOOK_URL}"
