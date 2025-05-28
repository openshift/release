#!/bin/bash

set -o errexit
set -o nounset

SLACK_NIGHTLY_WEBHOOK_URL=$(cat /tmp/secrets/SLACK_NIGHTLY_WEBHOOK_URL)
export SLACK_NIGHTLY_WEBHOOK_URL

get_job_url() {
  local job_base_url="https://prow.ci.openshift.org/view/gs/test-platform-results"
  local job_complete_url
  if [ -n "${PULL_NUMBER:-}" ]; then
    job_complete_url="${job_base_url}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
  else
    job_complete_url="${job_base_url}/logs/${JOB_NAME}/${BUILD_ID}"
  fi
  echo "${job_complete_url}"
}

main() {
  if [[ "$JOB_TYPE" != "periodic" ]]; then
    echo "This job is not a nightly job, skipping alert."
    exit 0
  fi

  SLACK_ALERT_MESSAGE=$(cat "${SHARED_DIR}/ci-slack-alert.txt")
  export SLACK_ALERT_MESSAGE
  URL_CI_RESULTS=$(get_job_url)

  if [[ -z "${SLACK_ALERT_MESSAGE}" ]]; then
    curl -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\":failed: \`$JOB_NAME\`, <$URL_CI_RESULTS|📜logs>.\"}" \
      "$SLACK_NIGHTLY_WEBHOOK_URL"
    exit 1
  fi

  curl -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"${SLACK_ALERT_MESSAGE}\"}" \
      "$SLACK_NIGHTLY_WEBHOOK_URL"
}

main
