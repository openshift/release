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
GANGWAY_URL="https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions"

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
  echo "Attempt ${attempt}/${MAX_ATTEMPTS}: triggering job..."

  # Make a request and store the HTTP status code
  http_code=$(curl -s -o "${ARTIFACT_DIR}/trigger_job.log" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -d "{\"job_name\": \"${JOB_NAME}\", \"job_execution_type\": \"${JOB_TYPE}\"}" \
    "${GANGWAY_URL}" 2>>"${ARTIFACT_DIR}/trigger_job.log") || true

  # Check for special failure case
  if [[ "${http_code}" == "000" ]]; then
    echo "ERROR: HTTP connection failure (DNS resolution, timeout, or refused)" >&2
  else
    echo "HTTP status code: ${http_code}"
  fi

  # If the status code in the response is lower or equal to 399, consider
  # the trigger successfully dispatched
  if [[ "${http_code}" =~ ^[0-9]+$ && "${http_code}" -gt 0 && "${http_code}" -le 399 ]]; then
    echo "Trigger succeeded"
    break
  fi

  echo "Trigger failed with HTTP status ${http_code}" >&2
  if [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; then
    echo "Retrying in ${SLEEP_SECONDS} seconds..."
    sleep "${SLEEP_SECONDS}"
  else
    echo "All ${MAX_ATTEMPTS} attempts failed" >&2
    exit 1
  fi
done
