#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="openshift-dev-installer"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
fi
gcloud config set project "${GOOGLE_PROJECT_ID}"

echo "$(date -u --rfc-3339=seconds) - Destroying GCP Subnets for Host Project..."

REGION="${LEASED_RESOURCE}"
INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
HOST_PROJECT_CONTROL_SUBNET="${INSTANCE_PREFIX}-subnet-1"
HOST_PROJECT_COMPUTE_SUBNET="${INSTANCE_PREFIX}-subnet-2"
HOST_PROJECT_NETWORK="${INSTANCE_PREFIX}-vpc"
NAT_NAME="${INSTANCE_PREFIX}-nat"

# Track deletion failures so we can report leaked resources at the end
declare -a FAILED_RESOURCES=()

# Best-effort delete: logs errors but continues to the next resource
function delete_resource() {
  local resource_description="$1"
  shift
  echo "$(date -u --rfc-3339=seconds) - Deleting ${resource_description}..."
  if ! "$@" 2>&1; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to delete ${resource_description}"
    FAILED_RESOURCES+=("${resource_description}")
  fi
}

# Retry delete with backoff for resources that may still be in use
function delete_resource_with_retry() {
  local resource_description="$1"
  local max_attempts=3
  local wait_seconds=30
  shift
  for attempt in $(seq 1 "${max_attempts}"); do
    echo "$(date -u --rfc-3339=seconds) - Deleting ${resource_description} (attempt ${attempt}/${max_attempts})..."
    if "$@" 2>&1; then
      return 0
    fi
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Deletion of ${resource_description} failed, retrying in ${wait_seconds}s..."
      sleep "${wait_seconds}"
    fi
  done
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to delete ${resource_description} after ${max_attempts} attempts"
  FAILED_RESOURCES+=("${resource_description}")
}

# Disable exit-on-error for the deletion section so all resources are attempted
set +e

delete_resource "firewall-rules ${INSTANCE_PREFIX}" \
  gcloud compute firewall-rules delete "${INSTANCE_PREFIX}" --quiet

delete_resource "NAT ${NAT_NAME}" \
  gcloud compute routers nats delete "${NAT_NAME}" --router="${INSTANCE_PREFIX}" --region="${REGION}" --quiet

delete_resource "router ${INSTANCE_PREFIX}" \
  gcloud compute routers delete "${INSTANCE_PREFIX}" --region "${REGION}" --quiet

delete_resource_with_retry "subnet ${HOST_PROJECT_CONTROL_SUBNET}" \
  gcloud compute networks subnets delete "${HOST_PROJECT_CONTROL_SUBNET}" --region "${REGION}" --quiet

delete_resource_with_retry "subnet ${HOST_PROJECT_COMPUTE_SUBNET}" \
  gcloud compute networks subnets delete "${HOST_PROJECT_COMPUTE_SUBNET}" --region "${REGION}" --quiet

delete_resource_with_retry "network ${HOST_PROJECT_NETWORK}" \
  gcloud compute networks delete "${HOST_PROJECT_NETWORK}" --quiet

# Re-enable exit-on-error
set -e

# Final verification: warn about any resources that could not be deleted
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo ""
  echo "$(date -u --rfc-3339=seconds) - WARNING: The following resources may have been leaked in project ${GOOGLE_PROJECT_ID}:"
  for resource in "${FAILED_RESOURCES[@]}"; do
    echo "  - ${resource}"
  done
  echo ""
  echo "$(date -u --rfc-3339=seconds) - Manual cleanup may be required."
  exit 1
else
  echo "$(date -u --rfc-3339=seconds) - All GCP XPN resources deleted successfully."
fi
