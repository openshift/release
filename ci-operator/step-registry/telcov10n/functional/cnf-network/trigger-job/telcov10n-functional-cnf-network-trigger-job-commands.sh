#!/bin/bash
set -e
set -o pipefail

# if job name does not include network, we remove the skip.txt to allow cascade triggering
echo "Validate JOB NAME variable: ${JOB_NAME}"
if [[ "${JOB_NAME}" != *"network"* ]]; then
  echo "JOB NAME does not include network — removing skip.txt"
  rm -f "${SHARED_DIR}/skip.txt"
fi

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Validate MULTISTAGE_PARAM_OVERRIDE_SKIP_CHAIN_TRIGGER variable: ${MULTISTAGE_PARAM_OVERRIDE_SKIP_CHAIN_TRIGGER}"
if [[ "${MULTISTAGE_PARAM_OVERRIDE_SKIP_CHAIN_TRIGGER,,}" = "true" ]]; then
  echo "🛑 MULTISTAGE_PARAM_OVERRIDE_SKIP_CHAIN_TRIGGER=true — skipping script"
  exit 0
fi

echo "Set trigger TOKEN env var"
TOKEN=$(cat /var/prow-trigger-token/token)

curl -v -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{\"job_name\": \"${JOB_NAME}\", \"job_execution_type\": \"${JOB_TYPE}\"}" \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions > ${ARTIFACT_DIR}/trigger_job.log 2>&1
