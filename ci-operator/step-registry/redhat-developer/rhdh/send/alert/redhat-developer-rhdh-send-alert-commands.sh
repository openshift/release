#!/bin/bash

set -o errexit
set +o nounset

RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')
SLACK_NIGHTLY_WEBHOOK_URL=$(cat /tmp/secrets/SLACK_NIGHTLY_WEBHOOK_URL)
export RELEASE_BRANCH_NAME SLACK_NIGHTLY_WEBHOOK_URL

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

# Align this function with the one in https://github.com/redhat-developer/rhdh/blob/main/.ibm/pipelines/reporting.sh
get_artifacts_url() {
  local project="${1:-""}"

  local artifacts_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
  local artifacts_complete_url
  JOB_NAME="periodic-ci-redhat-developer-rhdh-main-e2e-tests-nightly"

    local part_1="${JOB_NAME##periodic-ci-redhat-developer-rhdh-"${RELEASE_BRANCH_NAME}"-}" # e.g. "e2e-tests-aks-helm-nightly"
    local suite_name="${JOB_NAME##periodic-ci-redhat-developer-rhdh-"${RELEASE_BRANCH_NAME}"-e2e-tests-}" # e.g. "aks-helm-nightly"
    local part_2="redhat-developer-rhdh-${suite_name}" # e.g. "redhat-developer-rhdh-aks-helm-nightly"
    # Override part_2 based for specific cases that do not follow the standard naming convention.
    case "$JOB_NAME" in
      *osd-gcp*)
      part_2="redhat-developer-rhdh-osd-gcp-nightly"
      ;;
      *auth-providers*)
      part_2="redhat-developer-rhdh-auth-providers-nightly"
      ;;
      *ocp-v*)
      part_2="redhat-developer-rhdh-nightly"
      ;;
    esac
    artifacts_complete_url="${artifacts_base_url}/logs/${JOB_NAME}/${BUILD_ID}/artifacts/${part_1}/${part_2}/artifacts/${project}"
  echo "${artifacts_complete_url}"
}

get_slack_alert_text() {
  URL_CI_RESULTS=$(get_job_url)
  local notification_text

  if [[ $OVERALL_RESULT == 0 ]]; then
    notification_text=":done-circle-check: \`${JOB_NAME}\`, 📜 <$URL_CI_RESULTS|logs>."
  else
    notification_text=':failed: `'"${JOB_NAME}"'`, 📜 <'"$URL_CI_RESULTS"'|logs>, <!subteam^S07BMJ56R8S>.'
    for ((i = 1; i <= ${#STATUS_DEPLOYMENT_NAMESPACE[@]}; i++)); do
      URL_ARTIFACTS[i]=$(get_artifacts_url "${STATUS_DEPLOYMENT_NAMESPACE[i]}")
      URL_PLAYWRIGHT[i]="${URL_ARTIFACTS[i]}/index.html"
      if [[ "${STATUS_FAILED_TO_DEPLOY[i]}" == "true" ]]; then
        notification_text="${notification_text}\n• \`${STATUS_DEPLOYMENT_NAMESPACE[i]}\` :circleci-fail: failed to deploy, "
      else
        notification_text="${notification_text}\n• \`${STATUS_DEPLOYMENT_NAMESPACE[i]}\` :deployments: deployed, "
        if [[ "${STATUS_TEST_FAILED[i]}" == "true" ]]; then
          notification_text="${notification_text}:circleci-fail: ${STATUS_NUMBER_OF_TEST_FAILED[i]} tests failed, "
        else
          notification_text="${notification_text}:circleci-pass: test passed, "
        fi
        notification_text="${notification_text}:playwright: <${URL_PLAYWRIGHT[i]}|Playwright>, "
        if [[ "${STATUS_URL_REPORTPORTAL[i]}" != "" ]]; then
          notification_text="${notification_text}:reportportal: <${STATUS_URL_REPORTPORTAL[i]}|ReportPortal>, "
        fi
      fi
      notification_text="${notification_text}📦 <${URL_ARTIFACTS[i]}|artifacts>."
    done
  fi

  echo "${notification_text}"
}

main() {
  if [[ "$JOB_TYPE" != "periodic" ]]; then
    echo "This job is not a nightly job, skipping alert."
    exit 0
  fi

  echo "Reading status from $SHARED_DIR"
  local status_variables=(
    "STATUS_DEPLOYMENT_NAMESPACE"
    "STATUS_FAILED_TO_DEPLOY"
    "STATUS_TEST_FAILED"
    "STATUS_NUMBER_OF_TEST_FAILED"
    "STATUS_URL_REPORTPORTAL"
  )
  for status in "${status_variables[@]}"; do
    local file_name="${status}.txt"
    if [[ -f "$SHARED_DIR/$file_name" ]]; then
      echo "Reading $SHARED_DIR/$file_name"
      mapfile -t "${status}" < "$SHARED_DIR/$file_name"
    else
      echo "Notice: $SHARED_DIR/$file_name not found." >&2
    fi
  done

  if [[ -f "$SHARED_DIR/OVERALL_RESULT.txt" ]]; then
    OVERALL_RESULT=$(<"$SHARED_DIR/OVERALL_RESULT.txt")
  else
    echo "Notice: $SHARED_DIR/OVERALL_RESULT.txt not found, setting OVERALL_RESULT to 1." >&2
    OVERALL_RESULT=1
  fi

  echo "Getting Slack alert message"
  SLACK_ALERT_MESSAGE=$(get_slack_alert_text)

  if [[ -z "${SLACK_ALERT_MESSAGE}" || "${#STATUS_DEPLOYMENT_NAMESPACE[@]}" -eq 0 ]]; then
    URL_CI_RESULTS=$(get_job_url)
    URL_ARTIFACTS_TOP=$(get_artifacts_url)
    echo "No fine-grained results available, sending default message."
    curl -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\":failed: \`$JOB_NAME\`, 📜 <$URL_CI_RESULTS|logs>, 📦 <$URL_ARTIFACTS_TOP|artifacts>, <!subteam^S07BMJ56R8S>.\"}" \
      "$SLACK_NIGHTLY_WEBHOOK_URL"
    exit 1
  else
    echo "Sending Slack notification with the following text:"
    echo "==================================================="
    echo "${SLACK_ALERT_MESSAGE}"
    echo "==================================================="
    if ! curl -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"${SLACK_ALERT_MESSAGE}\"}" \
      "$SLACK_NIGHTLY_WEBHOOK_URL"; then
      echo "Failed to send alert message to Slack, error: $?"
      exit 1
    else
      echo "Alert message successfully sent to Slack."
      exit 0
    fi
  fi
}

main
