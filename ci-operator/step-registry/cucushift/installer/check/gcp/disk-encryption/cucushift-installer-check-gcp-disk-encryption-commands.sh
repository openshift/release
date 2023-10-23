#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${KMS_KEY_RING}" == "" ]] || [[ "${KMS_KEY_RING_LOCATION}" == "" ]] || [[ "${KMS_KEY_NAME}" == "" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Invalid OS disk custom encryption settings, abort." && exit 1
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

dir=$(mktemp -d)
pushd "${dir}"

## The expectations on OS disk custom encryption
project_id="${GOOGLE_PROJECT_ID}"
if [[ "${KMS_KEY_RING_PROJECT_ID}" != "" ]]; then
  project_id="${KMS_KEY_RING_PROJECT_ID}"
fi
expected_kmsKeyName="projects/${project_id}/locations/${KMS_KEY_RING_LOCATION}/keyRings/${KMS_KEY_RING}/cryptoKeys/${KMS_KEY_NAME}/cryptoKeyVersions/1"
echo "$(date -u --rfc-3339=seconds) - the expected kmsKeyName '${expected_kmsKeyName}'"

expected_kmsKeyServiceAccount="${sa_email}"
if [[ "${KMS_KEY_SERVICE_ACCOUNT}" != "" ]]; then
  expected_kmsKeyServiceAccount="${KMS_KEY_SERVICE_ACCOUNT}"
fi
echo "$(date -u --rfc-3339=seconds) - the expected kmsKeyServiceAccount '${expected_kmsKeyServiceAccount}'"

## Try the validation
ret=0

echo "$(date -u --rfc-3339=seconds) - Checking OS disk custom encryption of control-plane nodes..."
readarray -t control_plane_disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,zone)" | grep master)
for line in "${control_plane_disks[@]}"; do
  disk_name="${line%% *}"
  disk_zone="${line##* }"
  gcloud compute disks describe "${disk_name}" --zone "${disk_zone}" --format json > disk.json
  kmsKeyName=$(jq -r .diskEncryptionKey.kmsKeyName disk.json)
  if [[ "${kmsKeyName}" != "${expected_kmsKeyName}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected .diskEncryptionKey.kmsKeyName '${kmsKeyName}' for '${disk_name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched .diskEncryptionKey.kmsKeyName '${kmsKeyName}' for '${disk_name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - Checking OS disk custom encryption of compute nodes..."
readarray -t compute_disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,zone)" | grep worker)
for line in "${compute_disks[@]}"; do
  disk_name="${line%% *}"
  disk_zone="${line##* }"
  gcloud compute disks describe "${disk_name}" --zone "${disk_zone}" --format json > disk.json
  kmsKeyName=$(jq -r .diskEncryptionKey.kmsKeyName disk.json)
  kmsKeyServiceAccount=$(jq -r .diskEncryptionKey.kmsKeyServiceAccount disk.json)
  if [[ "${kmsKeyName}" != "${expected_kmsKeyName}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected .diskEncryptionKey.kmsKeyName '${kmsKeyName}' for '${disk_name}'."
    ret=1
  else
      echo "$(date -u --rfc-3339=seconds) - Matched .diskEncryptionKey.kmsKeyName '${kmsKeyName}' for '${disk_name}'."
  fi
  if [[ "${kmsKeyServiceAccount}" != "${expected_kmsKeyServiceAccount}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected .diskEncryptionKey.kmsKeyServiceAccount '${kmsKeyServiceAccount}' for '${disk_name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched .diskEncryptionKey.kmsKeyServiceAccount '${kmsKeyServiceAccount}' for '${disk_name}'."
  fi
done

popd
exit ${ret}
