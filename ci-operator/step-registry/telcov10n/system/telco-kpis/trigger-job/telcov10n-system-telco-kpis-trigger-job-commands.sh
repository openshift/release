#!/bin/bash
set -o pipefail

if [[ -z "${NEXT_JOB_NAME}" ]]; then
  echo "NEXT_JOB_NAME is empty — nothing to trigger"
  exit 0
fi

if [[ "${SKIP_CHAIN_TRIGGER,,}" == "true" ]]; then
  echo "SKIP_CHAIN_TRIGGER=true — skipping trigger"
  exit 0
fi

echo "Triggering next job in chain: ${NEXT_JOB_NAME}"

TOKEN=$(cat /var/prow-trigger-token/token)

curl -sf -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"job_name\": \"${NEXT_JOB_NAME}\", \"job_execution_type\": \"${JOB_TYPE}\"}" \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions \
  > "${ARTIFACT_DIR}/trigger_job.log" 2>&1

echo "Trigger request sent — see trigger_job.log for response"
