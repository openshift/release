#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

compute_disk_sizegb=$(yq-go r "${SHARED_DIR}/install-config.yaml" compute[0].platform.gcp.osDisk.diskSizeGB)
if [ -z "${compute_disk_sizegb}" ]; then
  compute_disk_sizegb=$(yq-go r "${SHARED_DIR}/install-config.yaml" platform.gcp.defaultMachinePlatform.osDisk.diskSizeGB)
fi
if [ -z "${compute_disk_sizegb}" ]; then
  compute_disk_sizegb="128"
fi

control_plane_disk_sizegb=$(yq-go r "${SHARED_DIR}/install-config.yaml" controlPlane.platform.gcp.osDisk.diskSizeGB)
if [ -z "${control_plane_disk_sizegb}" ]; then
  control_plane_disk_sizegb=$(yq-go r "${SHARED_DIR}/install-config.yaml" platform.gcp.defaultMachinePlatform.osDisk.diskSizeGB)
fi
if [ -z "${control_plane_disk_sizegb}" ]; then
  control_plane_disk_sizegb="128"
fi

## Try the validation
ret=0

echo "$(date -u --rfc-3339=seconds) - Checking OS disk sizeGb of cluster nodes..."
readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,sizeGb)" | grep -v NAME)
for line in "${disks[@]}"; do
  name="${line%% *}"
  size="${line##* }"
  if [[ "${name}" =~ worker ]]; then
    expected_size="${compute_disk_sizegb}"
  elif [[ "${name}" =~ master ]]; then
    expected_size="${control_plane_disk_sizegb}"
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
