#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

SECRETS_DIR=/run/secrets/ci.openshift.io/cluster-profile
GANGWAY_API_TOKEN=$(cat $SECRETS_DIR/gangway-api-token)
WEEKLY_JOBS="$SECRETS_DIR/$JSON_TRIGGER_LIST"
URL="https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com"

echo "# Printing the jobs-to-trigger JSON:"
jq -c '.[]' "$WEEKLY_JOBS"

echo ""
echo "# Test to make sure gangway api is up and running."
max_retries=60
retry_interval=60  # 60 seconds = 1 minute

for ((retry_count=1; retry_count<=$max_retries; retry_count++)); do
  response=$(curl -s -X GET -d '{"job_execution_type": "1"}' -H "Authorization: Bearer ${GANGWAY_API_TOKEN}" "${URL}/v1/executions/${PROW_JOB_ID}" -w "%{http_code}\n" -o /dev/null)

  if [ "$response" -eq 200 ]; then
    echo "Endpoint is up and returning HTTP status code 200 (OK)."
    break  # Exit the loop if successful response received
  else
    echo "Endpoint is not available or returned an error (HTTP status code $response). Retrying..."
  fi

  # Sleep for the specified interval before the next retry
  sleep $retry_interval
done

if [ "$response" -ne 200 ]; then
  echo "Endpoint is still not available after $max_retries retries. Aborting."
  exit 1
fi

max_retries=3
failed_jobs=""

echo ""
echo "# Loop through the trigger weekly jobs file using jq and issue a command for each job where 'active' is true"
jq -r '.[] | select(.active == true) | .job_name' "$WEEKLY_JOBS" | while IFS= read -r job; do
  echo "Issuing trigger for active job: $job"
  for ((retry_count=1; retry_count<=$max_retries; retry_count++)); do
    response=$(curl -s -X POST -d '{"job_execution_type": "1"}' -H "Authorization: Bearer ${GANGWAY_API_TOKEN}" "${URL}/v1/executions/$job" -w "%{http_code}\n" -o /dev/null)
    
    if [ "$response" -eq 200 ]; then
      echo "Trigger returned a 200 status code"
      break  # Exit the loop if successful response received
    else
      echo "We did not get a 200 status code from the job trigger. Retrying..."
    fi

    # Sleep for the specified interval before the next retry
    sleep $retry_interval
  done

  if [ "$response" -ne 200 ]; then
    echo "Trigger for active job: $job FAILED, a manual re-run is needed for $job"
    failed_jobs+="$job "  # Concatenate the job to the string of failed jobs
  fi

done

# Print the list of failed jobs after the loop completes
if [ -n "$failed_jobs" ]; then
  echo "The following jobs failed to trigger and need manual re-run:"
  echo "$failed_jobs"
else
  echo "No jobs failed to be triggered."
fi
