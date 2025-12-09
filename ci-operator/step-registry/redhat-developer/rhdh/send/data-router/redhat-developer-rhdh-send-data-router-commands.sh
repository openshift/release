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

# Constructs the artifacts URL for a given namespace based on CI job context
get_artifacts_url() {
  local namespace=$1

  if [ -z "${namespace}" ]; then
    echo "Warning: namespace parameter is empty" >&2
  fi

  local artifacts_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
  local artifacts_complete_url
  if [ -n "${PULL_NUMBER:-}" ]; then
    local part_1="${JOB_NAME##pull-ci-redhat-developer-rhdh-main-}"         # e.g. "e2e-ocp-operator-nightly"
    local suite_name="${JOB_NAME##pull-ci-redhat-developer-rhdh-main-e2e-}" # e.g. "ocp-operator-nightly"
    local part_2="redhat-developer-rhdh-${suite_name}"                      # e.g. "redhat-developer-rhdh-ocp-operator-nightly"
    # Override part_2 for specific cases that do not follow the standard naming convention.
    case "$JOB_NAME" in
      *osd-gcp*)
        part_2="redhat-developer-rhdh-osd-gcp-helm-nightly"
        ;;
      *ocp-v*helm*-nightly*)
        part_2="redhat-developer-rhdh-ocp-helm-nightly"
        ;;
    esac
    artifacts_complete_url="${artifacts_base_url}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/${part_1}/${part_2}/artifacts/${namespace}"
  else
    local part_1="${JOB_NAME##periodic-ci-redhat-developer-rhdh-"${RELEASE_BRANCH_NAME}"-}"         # e.g. "e2e-aks-helm-nightly"
    local suite_name="${JOB_NAME##periodic-ci-redhat-developer-rhdh-"${RELEASE_BRANCH_NAME}"-e2e-}" # e.g. "aks-helm-nightly"
    local part_2="redhat-developer-rhdh-${suite_name}"                                              # e.g. "redhat-developer-rhdh-aks-helm-nightly"
    # Override part_2 for specific cases that do not follow the standard naming convention.
    case "$JOB_NAME" in
      *osd-gcp*)
        part_2="redhat-developer-rhdh-osd-gcp-helm-nightly"
        ;;
      *ocp-v*helm*-nightly*)
        part_2="redhat-developer-rhdh-ocp-helm-nightly"
        ;;
    esac
    artifacts_complete_url="${artifacts_base_url}/logs/${JOB_NAME}/${BUILD_ID}/artifacts/${part_1}/${part_2}/artifacts/${namespace}"
  fi
  echo "${artifacts_complete_url}"
}

# Process JUnit files: replace attachment placeholders with URLs and fix XML property tags
process_junit_files() {
  echo "📝 Processing JUnit files for Data Router compatibility..."

  for junit_file in "${SHARED_DIR}"/junit-results-*.xml; do
    if [[ ! -f "$junit_file" ]]; then
      continue
    fi

    local filename
    filename=$(basename "$junit_file")
    echo "Processing: ${filename}"

    # Extract namespace from filename (e.g., "junit-results-showcase-ci-nightly.xml" -> "showcase-ci-nightly")
    local namespace
    namespace=$(echo "$filename" | sed 's/^junit-results-//' | sed 's/\.xml$//')

    # Create namespace directory in ARTIFACT_DIR if it doesn't exist
    mkdir -p "${ARTIFACT_DIR}/${namespace}"

    # Construct artifacts URL for this namespace
    local artifacts_url
    artifacts_url=$(get_artifacts_url "${namespace}")

    # Create backup of original file in ARTIFACT_DIR
    cp "$junit_file" "${ARTIFACT_DIR}/${namespace}/${filename}.original.xml"

    # Replace attachment placeholders with full URLs to OpenShift CI storage
    sed -i "s#\[\[ATTACHMENT|\(.*\)\]\]#${artifacts_url}/\1#g" "$junit_file"

    # Fix XML property tags format for Data Router compatibility
    # Step 1: Remove all closing property tags
    sed -i 's#</property>##g' "$junit_file"
    # Step 2: Convert opening property tags to self-closing format
    sed -i 's#<property name="\([^"]*\)" value="\([^"]*\)">#<property name="\1" value="\2"/>#g' "$junit_file"

    # Save the processed file to the artifact directory
    cp "$junit_file" "${ARTIFACT_DIR}/${namespace}/${filename}.processed.xml"

    echo "✅ Processed: ${filename} (namespace: ${namespace})"
  done

  echo "🗃️ JUnit files processed and ready for Data Router"
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

  # Process JUnit files before sending to Data Router
  process_junit_files

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
        DATA_ROUTER_REQUEST_OUTPUT=$(droute request get \
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
