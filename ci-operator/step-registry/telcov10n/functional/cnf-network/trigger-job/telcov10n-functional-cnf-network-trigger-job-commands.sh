#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

# Only trigger the next job in the chain if SKIP_CHAIN_TRIGGER is not set
# When manually triggering via curl, pass: "MULTISTAGE_PARAM_OVERRIDE_SKIP_CHAIN_TRIGGER": "true"
if [ "${SKIP_CHAIN_TRIGGER}" == "true" ]; then
  echo "SKIP_CHAIN_TRIGGER is set to true — skipping chain trigger to prevent cascade"
  exit 0
fi

echo "Set trigger TOKEN env var"
TOKEN=$(cat /var/prow-trigger-token/token)

curl -v -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{\"job_name\": \"${JOB_NAME}\", \"job_execution_type\": \"${JOB_TYPE}\"}" \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions > ${ARTIFACT_DIR}/trigger_job.log 2>&1
