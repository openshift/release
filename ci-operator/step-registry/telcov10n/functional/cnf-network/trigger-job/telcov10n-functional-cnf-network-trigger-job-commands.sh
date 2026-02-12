#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Set tigger TOKEN env var"
TOKEN=$(cat /var/prow-trigger-token/token)

curl -v -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{\"job_name\": \"${JOB_NAME}\", \"job_execution_type\": \"${JOB_TYPE}\"}" \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions > ${ARTIFACT_DIR}/trigger_job.log 2>&1
