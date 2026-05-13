#!/bin/bash

set +o errexit
set +o nounset

# Skip data router reporting when job was triggered via Gangway API with overrides
OVERRIDE_VARS=(
  "${MULTISTAGE_PARAM_OVERRIDE_GITHUB_ORG_NAME}"
  "${MULTISTAGE_PARAM_OVERRIDE_GITHUB_REPOSITORY_NAME}"
  "${MULTISTAGE_PARAM_OVERRIDE_RELEASE_BRANCH_NAME}"
  "${MULTISTAGE_PARAM_OVERRIDE_GIT_PR_NUMBER}"
)
for override in "${OVERRIDE_VARS[@]}"; do
  if [[ -n "${override}" ]]; then
    echo "Gangway API override detected, skipping data router reporting."
    exit 0
  fi
done

# =============================================================================
# RHDH Plugin Export Overlays — Data Router / ReportPortal Integration
#
# Sends JUnit test results from SHARED_DIR to Data Router for ReportPortal
# ingestion. Reads platform metadata written by the overlay test step.
#
# Prerequisites (written by the test step to SHARED_DIR):
#   - IS_OPENSHIFT.txt, CONTAINER_PLATFORM.txt, CONTAINER_PLATFORM_VERSION.txt
#   - RHDH_VERSION.txt
#   - junit-results.xml
# =============================================================================

RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')
export RELEASE_BRANCH_NAME

# ── Load secrets ─────────────────────────────────────────────────────────────

DATA_ROUTER_URL=$(cat /tmp/secrets/DATA_ROUTER_URL)
DATA_ROUTER_USERNAME=$(cat /tmp/secrets/DATA_ROUTER_USERNAME)
DATA_ROUTER_PASSWORD=$(cat /tmp/secrets/DATA_ROUTER_PASSWORD)
REPORTPORTAL_HOSTNAME=$(cat /tmp/secrets/REPORTPORTAL_HOSTNAME)
export DATA_ROUTER_URL DATA_ROUTER_USERNAME DATA_ROUTER_PASSWORD REPORTPORTAL_HOSTNAME

DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD="0.9"
DATA_ROUTER_PROJECT="main"
METADATA_OUTPUT="data_router_metadata_output.json"
export DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD DATA_ROUTER_PROJECT METADATA_OUTPUT

# ── Read platform info from SHARED_DIR ───────────────────────────────────────

IS_OPENSHIFT=$(cat "$SHARED_DIR/IS_OPENSHIFT.txt")
CONTAINER_PLATFORM=$(cat "$SHARED_DIR/CONTAINER_PLATFORM.txt")
CONTAINER_PLATFORM_VERSION=$(cat "$SHARED_DIR/CONTAINER_PLATFORM_VERSION.txt")
RHDH_VERSION=$(cat "$SHARED_DIR/RHDH_VERSION.txt" 2>/dev/null || echo "unknown")
export IS_OPENSHIFT CONTAINER_PLATFORM CONTAINER_PLATFORM_VERSION RHDH_VERSION

# ── Helper functions ─────────────────────────────────────────────────────────

save_status_data_router_failed() {
  local result=$1
  STATUS_DATA_ROUTER_FAILED=${result}
  echo "Saving STATUS_DATA_ROUTER_FAILED=${STATUS_DATA_ROUTER_FAILED}"
  printf "%s" "${STATUS_DATA_ROUTER_FAILED}" > "$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt"
  cp "$SHARED_DIR/STATUS_DATA_ROUTER_FAILED.txt" "$ARTIFACT_DIR/STATUS_DATA_ROUTER_FAILED.txt"
}

# Constructs the artifacts URL based on CI job context
get_artifacts_url() {
  local artifacts_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
  local artifacts_complete_url

  if [ -n "${PULL_NUMBER:-}" ]; then
    local part_1="${JOB_NAME##pull-ci-redhat-developer-rhdh-plugin-export-overlays-"${RELEASE_BRANCH_NAME}"-}"
    local part_2="redhat-developer-rhdh-plugin-export-overlays-ocp-helm"
    artifacts_complete_url="${artifacts_base_url}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/${part_1}/${part_2}/artifacts"
  else
    local part_1="${JOB_NAME##periodic-ci-redhat-developer-rhdh-plugin-export-overlays-"${RELEASE_BRANCH_NAME}"-}"
    local part_2="redhat-developer-rhdh-plugin-export-overlays-ocp-helm"
    artifacts_complete_url="${artifacts_base_url}/logs/${JOB_NAME}/${BUILD_ID}/artifacts/${part_1}/${part_2}/artifacts"
  fi

  echo "${artifacts_complete_url}"
}

# Process JUnit file: fix XML property tags for Data Router compatibility
process_junit_file() {
  echo "Processing JUnit file for Data Router compatibility..."

  local junit_file="${SHARED_DIR}/junit-results.xml"
  if [[ ! -f "$junit_file" ]]; then
    echo "WARNING: junit-results.xml not found in ${SHARED_DIR}, skipping processing"
    return
  fi

  echo "Processing: junit-results.xml"

  # Create backup in ARTIFACT_DIR
  mkdir -p "${ARTIFACT_DIR}/data-router"
  cp "$junit_file" "${ARTIFACT_DIR}/data-router/junit-results.xml.original.xml"

  # Construct artifacts URL for attachment placeholder replacement
  local artifacts_url
  artifacts_url=$(get_artifacts_url)

  # Replace attachment placeholders with full URLs to OpenShift CI storage.
  # Playwright generates relative paths like ../node_modules/.cache/e2e-test-results/...
  # which map to artifacts/e2e-test-results/... in GCS (collect_artifacts copies them there).
  sed -i "s#\[\[ATTACHMENT|\.\./node_modules/\.cache/\(.*\)\]\]#${artifacts_url}/\1#g" "$junit_file"
  # Catch any remaining attachment placeholders that don't match the pattern above
  sed -i "s#\[\[ATTACHMENT|\(.*\)\]\]#${artifacts_url}/\1#g" "$junit_file"

  # Fix XML property tags format for Data Router compatibility
  sed -i 's#</property>##g' "$junit_file"
  sed -i 's#<property name="\([^"]*\)" value="\([^"]*\)">#<property name="\1" value="\2"/>#g' "$junit_file"

  # Save the processed file
  cp "$junit_file" "${ARTIFACT_DIR}/data-router/junit-results.xml.processed.xml"

  echo "Processed: junit-results.xml"
  echo "JUnit file processed and ready for Data Router"
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
      return 1
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
  echo "${ARTIFACT_DIR}/${METADATA_OUTPUT}"
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

  # Parse PR number from JOB_SPEC (data-router step runs in a separate container)
  local pr_number=""
  pr_number=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number // empty' 2>/dev/null || true)

  jq -n \
    --arg hostname "$REPORTPORTAL_HOSTNAME" \
    --arg project "$DATA_ROUTER_PROJECT" \
    --arg name "$JOB_NAME" \
    --arg description "[View job run details](${JOB_URL})" \
    --arg job_type "$JOB_TYPE" \
    --arg pr "${pr_number:-}" \
    --arg job_name "$JOB_NAME" \
    --arg rhdh_version "$RHDH_VERSION" \
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
                {"key": "rhdh_version", "value": $rhdh_version},
                {"key": "install_method", "value": $install_method},
                {"key": "cluster_type", "value": $cluster_type},
                {"key": "container_platform", "value": $container_platform},
                {"key": "container_platform_version", "value": $container_platform_version},
                {"key": "component", "value": "plugins"}
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

  echo "Data Router metadata created and saved to ARTIFACT_DIR"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_required_vars || return 1

  save_data_router_metadata

  ls -la "${SHARED_DIR}"

  process_junit_file

  # Send test results through Data Router
  local max_attempts=10
  local wait_seconds_step=1
  local output=""
  local DATA_ROUTER_REQUEST_ID=""

  if [[ ! -f "${SHARED_DIR}/junit-results.xml" ]]; then
    echo "ERROR: No JUnit results file (junit-results.xml) found in ${SHARED_DIR}"
    return
  fi

  for ((i = 1; i <= max_attempts; i++)); do
    echo "Attempt ${i} of ${max_attempts} to send test results through Data Router."

    if output=$(droute send --metadata "$(get_metadata_output_path)" \
        --url "${DATA_ROUTER_URL}" \
        --username "${DATA_ROUTER_USERNAME}" \
        --password "${DATA_ROUTER_PASSWORD}" \
        --results "${SHARED_DIR}/junit-results.xml" \
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
      save_status_data_router_failed true
      return
    else
      echo "Attempt ${i} failed, retrying in $((wait_seconds_step * i)) seconds..."
      sleep $((wait_seconds_step * i))
    fi
  done

  # For periodic jobs, wait for completion and extract ReportPortal URL
  if [[ "$JOB_NAME" == *periodic-* ]]; then
    local poll_max_attempts=30
    local wait_seconds=2
    local DATA_ROUTER_REQUEST_OUTPUT=""
    local REPORTPORTAL_LAUNCH_URL=""

    for ((i = 1; i <= poll_max_attempts; i++)); do
      echo "Attempt ${i} of ${poll_max_attempts}: Checking Data Router request completion..."

      DATA_ROUTER_REQUEST_OUTPUT=$(droute request get \
        --url "${DATA_ROUTER_URL}" \
        --username "${DATA_ROUTER_USERNAME}" \
        --password "${DATA_ROUTER_PASSWORD}" \
        "${DATA_ROUTER_REQUEST_ID}")

      REPORTPORTAL_LAUNCH_URL=$(echo "$DATA_ROUTER_REQUEST_OUTPUT" | grep -o 'https://[^"]*')

      if [[ -n "$REPORTPORTAL_LAUNCH_URL" ]]; then
        echo "ReportPortal launch URL found: ${REPORTPORTAL_LAUNCH_URL}"
        save_status_url_reportportal "$REPORTPORTAL_LAUNCH_URL"
        save_status_data_router_failed false
        return 0
      else
        echo "Attempt ${i} of ${poll_max_attempts}: ReportPortal launch URL not ready yet."
        if ((i < poll_max_attempts)); then
          sleep "${wait_seconds}"
        fi
      fi
    done

    echo "Warning: Could not retrieve ReportPortal launch URL after ${poll_max_attempts} attempts"
  fi
}

main
