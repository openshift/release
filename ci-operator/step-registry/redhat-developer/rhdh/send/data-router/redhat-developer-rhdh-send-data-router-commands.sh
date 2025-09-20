#!/bin/bash

set +o errexit
set +o nounset

RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')
export RELEASE_BRANCH_NAME

# Load required variables from secrets
DATA_ROUTER_URL=$(cat /tmp/secrets/DATA_ROUTER_URL)
DATA_ROUTER_USERNAME=$(cat /tmp/secrets/DATA_ROUTER_USERNAME)
DATA_ROUTER_PASSWORD=$(cat /tmp/secrets/DATA_ROUTER_PASSWORD)
REPORTPORTAL_HOSTNAME=$(cat /tmp/secrets/REPORTPORTAL_HOSTNAME)
export DATA_ROUTER_URL DATA_ROUTER_USERNAME DATA_ROUTER_PASSWORD REPORTPORTAL_HOSTNAME

DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD="0.9"
DATA_ROUTER_PROJECT="main"
METADATA_OUTPUT="data_router_metadata_output.json"
export DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD DATA_ROUTER_PROJECT METADATA_OUTPUT

IS_OPENSHIFT=$(cat $SHARED_DIR/IS_OPENSHIFT.txt)
CONTAINER_PLATFORM=$(cat $SHARED_DIR/CONTAINER_PLATFORM.txt)
CONTAINER_PLATFORM_VERSION=$(cat $SHARED_DIR/CONTAINER_PLATFORM_VERSION.txt)
export IS_OPENSHIFT CONTAINER_PLATFORM CONTAINER_PLATFORM_VERSION

save_status_data_router_failed() {
  local result=$1
  STATUS_DATA_ROUTER_FAILED=${result}
  echo "Saving STATUS_DATA_ROUTER_FAILED=${STATUS_DATA_ROUTER_FAILED}"
  printf "%s" "${STATUS_DATA_ROUTER_FAILED}" > "$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt"
  cp "$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt" "$ARTIFACT_DIR/STATUS_DATA_ROUTER_FAILED.txt"
}

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
  save_status_data_router_failed true
fi

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

save_data_router_metadata() {
  JOB_URL=$(get_job_url)
  local install_method
  local cluster_type

  # Set install_method based on job name
  if [[ "$JOB_NAME" == *operator* ]]; then
    install_method="operator"
  else
    install_method="helm-chart"
  fi

  # Set cluster_type based on IS_OPENSHIFT
  if [[ "$IS_OPENSHIFT" == "true" ]]; then
    cluster_type="openshift"
  else
    cluster_type="kubernetes"
  fi

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
    --arg install_method "$install_method" \
    --arg cluster_type "$cluster_type" \
    --arg container_platform "$CONTAINER_PLATFORM" \
    --arg container_platform_version "$CONTAINER_PLATFORM_VERSION" \
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
                {"key": "tag_name", "value": $tag_name},
                {"key": "install_method", "value": $install_method},
                {"key": "cluster_type", "value": $cluster_type},
                {"key": "container_platform", "value": $container_platform},
                {"key": "container_platform_version", "value": $container_platform_version}
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

      if output=$(droute send --metadata "$(get_metadata_output_path)" \
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
        DATA_ROUTER_REQUEST_OUTPUT=$(`droute` request get \
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
