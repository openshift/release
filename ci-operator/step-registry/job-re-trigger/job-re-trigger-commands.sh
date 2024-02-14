#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

if [ "${RE_TRIGGER_ON_FAILURE}" = "true" ]; then

  SERVER_URL=$(cat "${CLUSTER_PROFILE_DIR}/openshift-ci-job-trigger-server-url")
  TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/openshift-ci-api-token")

  if [ -z "$SERVER_URL" ]; then
    echo "openshift-ci-job-trigger-server-url is empty"
    exit 1
  fi

  if [ -z "$TOKEN" ]; then
    echo "openshift-ci-api-token is empty"
    exit 1
  fi

  curl -X POST  "$SERVER_URL" -d '{"job_name":"'"$JOB_NAME"'", "build_id": "'"$BUILD_ID"'", "prow_job_id":"'"$PROW_JOB_ID"'", "token":  "'"$TOKEN"'"}' -H "Content-Type: application/json"

fi