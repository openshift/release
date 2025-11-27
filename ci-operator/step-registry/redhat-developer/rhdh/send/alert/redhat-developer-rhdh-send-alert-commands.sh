#!/bin/bash

set -o errexit
set +o nounset

if [[ "$JOB_TYPE" != "periodic" ]]; then
  echo "This job is not a nightly job, skipping alert."
  exit 0
fi

RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')
SLACK_NIGHTLY_WEBHOOK_URL=$(cat /tmp/secrets/SLACK_NIGHTLY_WEBHOOK_URL)
export RELEASE_BRANCH_NAME SLACK_NIGHTLY_WEBHOOK_URL

# Download and source the reporting.sh file from RHDH repository
REPORTING_SCRIPT_URL="https://raw.githubusercontent.com/redhat-developer/rhdh/${RELEASE_BRANCH_NAME}/.ibm/pipelines/reporting.sh"
REPORTING_SCRIPT_TMP="/tmp/reporting.sh"

echo "💾 Downloading reporting.sh from ${REPORTING_SCRIPT_URL}"
if curl -f -s -o "${REPORTING_SCRIPT_TMP}" "${REPORTING_SCRIPT_URL}"; then
  echo "🟢 Successfully downloaded reporting.sh, sourcing it..."
  # shellcheck source=/dev/null
  source "${REPORTING_SCRIPT_TMP}"
  rm -f "${REPORTING_SCRIPT_TMP}"
  echo "✅ Successfully sourced reporting.sh from redhat-developer/rhdh/${RELEASE_BRANCH_NAME}"
else
  echo "🔴 Error: Failed to download reporting.sh from ${REPORTING_SCRIPT_URL}"
  exit 1
fi

get_slack_alert_text() {
  URL_CI_RESULTS=$(get_job_url)
  local notification_text
  local status_icon
  local needs_mention=false

  if [[ $OVERALL_RESULT == 0 ]]; then
    status_icon=":done-circle-check:"
  else
    status_icon=":failed:"
    needs_mention=true
  fi

  # Build base notification
  notification_text="${status_icon} \`${JOB_NAME}\`, 📜 <$URL_CI_RESULTS|logs>"

  # Add ReportPortal URL or Data Router failure note
  if [[ -n "${STATUS_URL_REPORTPORTAL}" ]]; then
    notification_text="${notification_text}, :reportportal: <${STATUS_URL_REPORTPORTAL}|ReportPortal>"
  elif [[ "${STATUS_DATA_ROUTER_FAILED}" == "true" ]]; then
    notification_text="${notification_text}, :warning: Data Router failed"
  fi

  # Add mention for failures
  if [[ "$needs_mention" == "true" ]]; then
    notification_text="${notification_text}, <!subteam^S07BMJ56R8S> <@U08UP0REWG1>"
  fi

  notification_text="${notification_text}."

  # Add deployment details for failures
  if [[ $OVERALL_RESULT != 0 ]]; then
    for ((i = 0; i < ${#STATUS_DEPLOYMENT_NAMESPACE[@]}; i++)); do
      URL_ARTIFACTS[i]=$(get_artifacts_url "${STATUS_DEPLOYMENT_NAMESPACE[i]}")
      URL_PLAYWRIGHT[i]="${URL_ARTIFACTS[i]}/index.html"
      if [[ "${STATUS_FAILED_TO_DEPLOY[i]}" == "true" ]]; then
        notification_text="${notification_text}\n• \`${STATUS_DEPLOYMENT_NAMESPACE[i]}\` :circleci-fail: failed to deploy, "
      else
        notification_text="${notification_text}\n• \`${STATUS_DEPLOYMENT_NAMESPACE[i]}\` :deployments: deployed, "
        if [[ "${STATUS_TEST_FAILED[i]}" == "true" ]]; then
          notification_text="${notification_text}:circleci-fail: ${STATUS_NUMBER_OF_TEST_FAILED[i]} tests failed, "
        else
          notification_text="${notification_text}:circleci-pass: tests passed, "
        fi
        notification_text="${notification_text}:playwright: <${URL_PLAYWRIGHT[i]}|Playwright>, "
      fi
      notification_text="${notification_text}📦 <${URL_ARTIFACTS[i]}|artifacts>."
    done
  fi

  echo "${notification_text}"
}

main() {
  echo "Reading status from $SHARED_DIR"
  local status_variables=(
    "STATUS_DEPLOYMENT_NAMESPACE"
    "STATUS_FAILED_TO_DEPLOY"
    "STATUS_TEST_FAILED"
    "STATUS_NUMBER_OF_TEST_FAILED"
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

  # Read STATUS_URL_REPORTPORTAL as a single value
  if [[ -f "$SHARED_DIR/STATUS_URL_REPORTPORTAL.txt" ]]; then
    echo "Reading $SHARED_DIR/STATUS_URL_REPORTPORTAL.txt"
    STATUS_URL_REPORTPORTAL=$(<"$SHARED_DIR/STATUS_URL_REPORTPORTAL.txt")
  else
    echo "Notice: $SHARED_DIR/STATUS_URL_REPORTPORTAL.txt not found." >&2
    STATUS_URL_REPORTPORTAL=""
  fi

  # Read STATUS_DATA_ROUTER_FAILED as a single value
  if [[ -f "$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt" ]]; then
    echo "Reading $SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt"
    STATUS_DATA_ROUTER_FAILED=$(<"$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt")
  else
    echo "Notice: $SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt not found." >&2
    STATUS_DATA_ROUTER_FAILED="false"
  fi

  if [[ -f "$SHARED_DIR/OVERALL_RESULT.txt" ]]; then
    echo "Reading $SHARED_DIR/OVERALL_RESULT.txt"
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
      --data "{\"text\":\":failed: \`$JOB_NAME\`, 📜 <$URL_CI_RESULTS|logs>, 📦 <$URL_ARTIFACTS_TOP|artifacts>, <!subteam^S07BMJ56R8S> <@U08UP0REWG1>.\"}" \
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
