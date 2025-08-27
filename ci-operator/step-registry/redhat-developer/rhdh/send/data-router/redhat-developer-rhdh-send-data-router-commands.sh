#!/bin/bash

set +o errexit
set +o nounset

# if [[ "${JOB_NAME}" == *rehearse* ]]; then
#   echo "This job is a rehearse job, skipping Data Router."
#   return 0
# fi

RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')

# Load required variables from secrets
DATA_ROUTER_URL=$(cat /tmp/secrets/DATA_ROUTER_URL)
DATA_ROUTER_USERNAME=$(cat /tmp/secrets/DATA_ROUTER_USERNAME)
DATA_ROUTER_PASSWORD=$(cat /tmp/secrets/DATA_ROUTER_PASSWORD)
REPORTPORTAL_HOSTNAME=$(cat /tmp/secrets/REPORTPORTAL_HOSTNAME)

DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD="0.9"
DATA_ROUTER_PROJECT="main"
METADATA_OUTPUT="data_router_metadata_output.json"

export RELEASE_BRANCH_NAME DATA_ROUTER_URL DATA_ROUTER_USERNAME DATA_ROUTER_PASSWORD DATA_ROUTER_PROJECT DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD REPORTPORTAL_HOSTNAME METADATA_OUTPUT

# Validate required variables
validate_required_vars() {
  local required_vars=(
    "DATA_ROUTER_URL"
    "DATA_ROUTER_USERNAME"
    "DATA_ROUTER_PASSWORD"
    "REPORTPORTAL_HOSTNAME"
  )

  for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
      echo "ERROR: Required variable ${var} is not set"
      exit 1
    fi
  done
}

save_status_data_router_failed() {
  local result=$1
  STATUS_DATA_ROUTER_FAILED=${result}
  echo "Saving STATUS_DATA_ROUTER_FAILED=${STATUS_DATA_ROUTER_FAILED}"
  printf "%s" "${STATUS_DATA_ROUTER_FAILED}" > "$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt"
  cp "$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt" "$ARTIFACT_DIR/STATUS_DATA_ROUTER_FAILED.txt"
}

save_status_url_reportportal() {
  local url=$1
  STATUS_URL_REPORTPORTAL=${url}
  echo "Saving STATUS_URL_REPORTPORTAL=${STATUS_URL_REPORTPORTAL}"
  printf "%s" "${STATUS_URL_REPORTPORTAL}" > "$SHARED_DIR/STATUS_URL_REPORTPORTAL.txt"
  cp "$SHARED_DIR/STATUS_URL_REPORTPORTAL.txt" "$ARTIFACT_DIR/STATUS_URL_REPORTPORTAL.txt"
}

get_metadata_output_path() {
  local metadata_output="data_router_metadata_output.json"
  echo "${ARTIFACT_DIR}/${metadata_output}"
}

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

save_data_router_metadata() {
  JOB_URL=$(get_job_url)

  # Generate the metadata file for Data Router from the template
  jq -n \
    --arg hostname "$REPORTPORTAL_HOSTNAME" \
    --arg project "$DATA_ROUTER_PROJECT" \
    --arg name "$JOB_NAME" \
    --arg description "[View job run details](${JOB_URL})" \
    --arg job_type "$JOB_TYPE" \
    --arg pr "$GIT_PR_NUMBER" \
    --arg job_name "$JOB_NAME" \
    --arg tag_name "$TAG_NAME" \
    --argjson auto_finalization_threshold "$DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD" \
    '{
      "targets": {
        "reportportal": {
          "disabled": false,
          "config": {
            "hostname": $hostname,
            "project": $project
          },
          "processing": {
            "apply_tfa": true,
            "property_filter": [".*"],
            "launch": {
              "name": $name,
              "description": $description,
              "attributes": [
                {"key": "job_type", "value": $job_type},
                {"key": "pr", "value": $pr},
                {"key": "job_name", "value": $job_name},
                {"key": "tag_name", "value": $tag_name}
              ]
            },
            "tfa": {
              "add_attributes": true,
              "auto_finalize_defect_type": true,
              "auto_finalization_threshold": $auto_finalization_threshold
            }
          }
        }
      }
    }' > "$(get_metadata_output_path)"

  echo "🗃️ Data Router metadata created and saved to ARTIFACT_DIR"
}

main() {
  # Validate required variables before proceeding
  validate_required_vars

  save_data_router_metadata

  ls -la "${SHARED_DIR}"

  # Send test results through DataRouter and save the request ID.
    local max_attempts=10
    local wait_seconds_step=1
    local output=""
    local DATA_ROUTER_REQUEST_ID=""

    for ((i = 1; i <= max_attempts; i++)); do
      echo "Attempt ${i} of ${max_attempts} to send test results through Data Router."

      # Check if JUnit results files exist in SHARED_DIR
      local junit_files_found=false
      for file in "${SHARED_DIR}"/junit-*.xml; do
        if [[ -f "$file" ]]; then
          junit_files_found=true
          break
        fi
      done

      if [[ "$junit_files_found" == false ]]; then
        echo "ERROR: No JUnit results files (junit-*.xml) found in ${SHARED_DIR}"
        return
      fi

      if output=$(/droute send --metadata "$(get_metadata_output_path)" \
          --url "${DATA_ROUTER_URL}" \
          --username "${DATA_ROUTER_USERNAME}" \
          --password "${DATA_ROUTER_PASSWORD}" \
          --results "${SHARED_DIR}/junit-*.xml" \
          --verbose --wirelog 2>&1) && \
        DATA_ROUTER_REQUEST_ID=$(echo "$output" | grep "request:" | awk '{print $2}') &&
        [ -n "$DATA_ROUTER_REQUEST_ID" ]; then
        echo "Test results successfully sent through Data Router."
        echo "Request ID: $DATA_ROUTER_REQUEST_ID"
        break
      elif ((i == max_attempts)); then
        echo "Failed to send test results after ${max_attempts} attempts."
        echo "Last Data Router error details:"
        echo "${output}"
        echo "Troubleshooting steps:"
        echo "1. Check for outages at Slack channel: #forum-dno-datarouter"
        echo "2. Check the Data Router documentation: https://spaces.redhat.com/spaces/CentralCI/pages/115488042/D+O+Data+Router"
        echo "3. Ask for help at Slack channel: #forum-dno-datarouter"
        save_status_data_router_failed true
        return
      else
        echo "Attempt ${i} failed, retrying in $((wait_seconds_step * i)) seconds..."
        sleep $((wait_seconds_step * i))
      fi
    done

    # For periodic jobs, wait for completion and extract ReportPortal URL
    if [[ "$JOB_NAME" == *periodic-* ]]; then
      local max_attempts=30
      local wait_seconds=2
      local DATA_ROUTER_REQUEST_OUTPUT=""
      local REPORTPORTAL_LAUNCH_URL=""

      for ((i = 1; i <= max_attempts; i++)); do
        echo "Attempt ${i} of ${max_attempts}: Checking Data Router request completion..."

        # Get DataRouter request information.
        DATA_ROUTER_REQUEST_OUTPUT=$(/droute request get \
          --url "${DATA_ROUTER_URL}" \
          --username "${DATA_ROUTER_USERNAME}" \
          --password "${DATA_ROUTER_PASSWORD}" \
          "${DATA_ROUTER_REQUEST_ID}")

        # Try to extract the ReportPortal launch URL from the request. This fails if it doesn't contain the launch URL.
        REPORTPORTAL_LAUNCH_URL=$(echo "$DATA_ROUTER_REQUEST_OUTPUT" | grep -o 'https://[^"]*')

        if [[ -n "$REPORTPORTAL_LAUNCH_URL" ]]; then
          echo "ReportPortal launch URL found: ${REPORTPORTAL_LAUNCH_URL}"
          save_status_url_reportportal "$REPORTPORTAL_LAUNCH_URL"
          save_status_data_router_failed false
          return 0
        else
          echo "Attempt ${i} of ${max_attempts}: ReportPortal launch URL not ready yet."
          if ((i < max_attempts)); then
            sleep "${wait_seconds}"
          fi
        fi
      done

      echo "Warning: Could not retrieve ReportPortal launch URL after ${max_attempts} attempts"
    fi
}

main
