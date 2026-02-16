#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Skip in rehearsal mode
if [[ "${JOB_NAME:-}" == *"rehearse"* ]]; then
  echo "Running in rehearsal mode, skipping build watcher execution"
  exit 0
fi

# Configuration
GANGWAY_URL="https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com"
DECK_URL="https://prow.ci.openshift.org"
CINCINNATI_BASE_URL="https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream"
SECRETS_DIR="${SECRETS_DIR:-/var/run/osc-secrets}"
JOB_PREFIX="periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release"

# OCP versions to watch (major.minor format)
OCP_VERSIONS=("4.17" "4.18" "4.19" "4.20" "4.21" "4.22")

# Jobs to trigger for each OCP version
JOBS_TO_TRIGGER=(
  "azure-ipi-kata"
  "azure-ipi-peerpods"
  "azure-ipi-coco"
  "aws-ipi-peerpods"
  "aws-ipi-coco"
)

# Time window to check for recent runs (in days)
DAYS_TO_CHECK=1

echo "========================================="
echo "OpenShift Sandboxed Containers Build Watcher"
echo "========================================="
echo "Date: $(date)"
echo ""

# Read Gangway API token
if [ ! -f "${SECRETS_DIR}/gangway-api-token" ]; then
  echo "ERROR: Gangway API token not found at ${SECRETS_DIR}/gangway-api-token"
  exit 1
fi

GANGWAY_API_TOKEN=$(cat "${SECRETS_DIR}/gangway-api-token")
echo "✓ Gangway API token loaded"
echo ""

# Function to get latest accepted release for an OCP version
get_latest_release() {
  local ocp_version=$1
  local release_stream="${ocp_version}.0-0.nightly"

  echo "Querying Cincinnati API for ${release_stream}..."
  local response
  response=$(curl -s "${CINCINNATI_BASE_URL}/${release_stream}/latest" || echo "")

  if [ -z "$response" ]; then
    echo "  ⚠ Failed to query Cincinnati API for ${release_stream}"
    return 1
  fi

  local name phase
  name=$(echo "$response" | jq -r '.name // empty')
  phase=$(echo "$response" | jq -r '.phase // empty')

  if [ -z "$name" ] || [ "$phase" != "Accepted" ]; then
    echo "  ⚠ No accepted release found for ${release_stream}"
    return 1
  fi

  echo "  ✓ Latest accepted release: ${name}"
  echo "$name"
  return 0
}

# Function to check if OCP version was recently tested
check_recent_test() {
  local job_name=$1
  local ocp_version=$2

  echo "  Checking if ${job_name} was tested with ${ocp_version} in last ${DAYS_TO_CHECK} days..."

  # Query Deck API for recent ProwJobs
  local prowjobs_response
  prowjobs_response=$(curl -s "${DECK_URL}/prowjobs.js?var=allBuilds" || echo "")

  if [ -z "$prowjobs_response" ]; then
    echo "    ⚠ Failed to query Deck API"
    return 1
  fi

  # Calculate timestamp for N days ago (in seconds since epoch)
  local cutoff_time
  cutoff_time=$(date -d "${DAYS_TO_CHECK} days ago" +%s)

  # Check if job was run recently with success
  # Note: This is a simplified check - in production you might want to parse job artifacts
  # to verify the exact OCP version tested
  local recent_success
  recent_success=$(echo "$prowjobs_response" | \
    jq -r --arg job "${job_name}" --arg cutoff "${cutoff_time}" \
    '.items[]? | select(.spec.job == $job and .status.state == "success") |
    select((.metadata.creationTimestamp | fromdateiso8601) > ($cutoff | tonumber)) |
    .metadata.creationTimestamp' | head -1)

  if [ -n "$recent_success" ]; then
    echo "    ✓ Recent successful run found: ${recent_success}"
    return 0
  fi

  echo "    ✗ No recent successful run found"
  return 1
}

# Function to trigger a job via Gangway API
trigger_job() {
  local job_name=$1

  echo "  Triggering job: ${job_name}"

  local response http_code
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${GANGWAY_API_TOKEN}" \
    -d '{"job_execution_type": "1"}' \
    "${GANGWAY_URL}/v1/executions/${job_name}" || echo -e "\n000")

  http_code=$(echo "$response" | tail -1)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    echo "    ✓ Successfully triggered (HTTP ${http_code})"
    return 0
  else
    echo "    ✗ Failed to trigger (HTTP ${http_code})"
    echo "$response" | head -n -1
    return 1
  fi
}

# Main logic
echo "Checking OCP versions for new releases..."
echo ""

triggered_count=0
skipped_count=0
failed_count=0

for ocp_version in "${OCP_VERSIONS[@]}"; do
  echo "----------------------------------------"
  echo "Processing OCP ${ocp_version}"
  echo "----------------------------------------"

  # Get latest accepted release
  latest_release=$(get_latest_release "$ocp_version") || {
    echo "  Skipping ${ocp_version} - no release available"
    echo ""
    continue
  }

  # Check each job
  for job_suffix in "${JOBS_TO_TRIGGER[@]}"; do
    full_job_name="${JOB_PREFIX}-${job_suffix}"

    echo ""
    echo "Job: ${full_job_name}"

    # Check if recently tested
    if check_recent_test "$full_job_name" "$latest_release"; then
      echo "    → Skipping (already tested recently)"
      ((skipped_count++))
      continue
    fi

    # Trigger the job
    if trigger_job "$full_job_name"; then
      echo "    → Triggered for OCP ${latest_release}"
      ((triggered_count++))
    else
      echo "    → Failed to trigger"
      ((failed_count++))
    fi
  done

  echo ""
done

echo "========================================="
echo "Summary"
echo "========================================="
echo "Jobs triggered: ${triggered_count}"
echo "Jobs skipped:   ${skipped_count}"
echo "Jobs failed:    ${failed_count}"
echo ""

if [ $failed_count -gt 0 ]; then
  echo "⚠ Some jobs failed to trigger"
  exit 1
fi

echo "✓ Build watcher completed successfully"
exit 0
