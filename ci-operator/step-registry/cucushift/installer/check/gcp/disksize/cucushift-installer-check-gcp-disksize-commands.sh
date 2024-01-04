#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


if [ -z "${COMPUTE_DISK_SIZEGB}" ] && [ -z "${CONTROL_PLANE_DISK_SIZEGB}" ]; then
  echo "Empty 'COMPUTE_DISK_SIZEGB' and 'CONTROL_PLANE_DISK_SIZEGB', nothing to do, exiting."
  exit 0
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

echo "COMPUTE_DISK_SIZEGB: ${COMPUTE_DISK_SIZEGB}"
echo "CONTROL_PLANE_DISK_SIZEGB: ${CONTROL_PLANE_DISK_SIZEGB}"

## Try the validation
ret=0

echo "$(date -u --rfc-3339=seconds) - Checking OS disk type of cluster nodes..."
readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,sizeGb)" | grep -v NAME)
for line in "${disks[@]}"; do
  name="${line%% *}"
  size="${line##* }"
  if [[ "${name}" =~ worker ]] && [[ -n "${COMPUTE_DISK_SIZEGB}" ]]; then
    expected_size="${COMPUTE_DISK_SIZEGB}"
  elif [[ "${name}" =~ master ]] && [[ -n "${CONTROL_PLANE_DISK_SIZEGB}" ]]; then
    expected_size="${CONTROL_PLANE_DISK_SIZEGB}"
  else
    echo "$(date -u --rfc-3339=seconds) - Skip disk '${name}'."
    continue 
  fi
  if [[ "${size}" != "${expected_size}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected .sizeGb '${size}' for '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched .sizeGb '${size}' for '${name}'."
  fi
done

echo "Exit code '${ret}'"
exit ${ret}
