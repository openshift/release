#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/compute-osdisk-disktype" ]; then
  echo "$(date -u --rfc-3339=seconds) - Nothing to do, skip." && exit 0
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

## The expected OS disk type of compute nodes
expected_disk_type=$(cat "${SHARED_DIR}/compute-osdisk-disktype")

## Try the validation
ret=0

readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,type)" | grep worker)
if [[ ${#disks[@]} == 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - Zero compute/worker node found."
  exit ${ret}
fi

echo "$(date -u --rfc-3339=seconds) - Checking OS disk type of compute nodes..."
for line in "${disks[@]}"; do
  name="${line%% *}"
  type="${line##* }"
  if [[ "${type}" != "${expected_disk_type}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected .type '${type}' for '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched .type '${type}' for '${name}'."
  fi
done

exit ${ret}
