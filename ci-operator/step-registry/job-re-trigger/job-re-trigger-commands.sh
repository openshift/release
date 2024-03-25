#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

if [ "${RE_TRIGGER_ON_FAILURE}" = "true" ]; then

  SERVER_URL=$(cat "${CLUSTER_PROFILE_DIR}/openshift-ci-job-trigger-server-url")
  TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/openshift-ci-api-token")

  if [ -f "${CLUSTER_PROFILE_DIR}/openshift-ci-job-trigger-slack-webhook-url" ]; then
    SLACK_WEBHOOK_URL=$(cat "${CLUSTER_PROFILE_DIR}/openshift-ci-job-trigger-slack-webhook-url")
  fi

  if [ -f "${CLUSTER_PROFILE_DIR}/openshift-ci-job-trigger-slack-error-webhook-url" ]; then
    SLACK_ERROR_WEBHOOK_URL=$(cat "${CLUSTER_PROFILE_DIR}/openshift-ci-job-trigger-slack-error-webhook-url")
  fi

  if [ -z "$SERVER_URL" ]; then
    echo "openshift-ci-job-trigger-server-url is empty"
    exit 1
  fi

  if [ -z "$TOKEN" ]; then
    echo "openshift-ci-api-token is empty"
    exit 1
  fi

  echo "Send job re-triggering for job ${JOB_NAME}, build ${BUILD_ID} prow job ${PROW_JOB_ID}"

  json_payload='"job_name":"'"$JOB_NAME"'", "build_id": "'"$BUILD_ID"'", "prow_job_id":"'"$PROW_JOB_ID"'", "trigger_token": "'"$TOKEN"'"'

  if [ -n "$SLACK_WEBHOOK_URL" ]; then
    json_payload+=', "slack_webhook_url": "'"$SLACK_WEBHOOK_URL"'"'
  fi

  if [ -n "$SLACK_ERROR_WEBHOOK_URL" ]; then
    json_payload+=', "slack_errors_webhook_url": "'"$SLACK_ERROR_WEBHOOK_URL"'"'
  fi

  curl -X POST "$SERVER_URL" -d "{$json_payload}" -H "Content-Type: application/json"

else
  echo "RE_TRIGGER_ON_FAILURE is set to false; job was not re-triggered"

fi
