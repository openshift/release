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

## The expected OS disk type of compute nodes
compute_disk_type=$(yq-go r "${SHARED_DIR}/install-config.yaml" compute[0].platform.gcp.osDisk.diskType)
if [ -z "${compute_disk_type}" ]; then
  compute_disk_type=$(yq-go r "${SHARED_DIR}/install-config.yaml" platform.gcp.defaultMachinePlatform.osDisk.diskType)
fi
if [ -z "${compute_disk_type}" ]; then
  compute_disk_type="pd-ssd"
fi

## The expected OS disk type of control-plane nodes
control_plane_disk_type=$(yq-go r "${SHARED_DIR}/install-config.yaml" controlPlane.platform.gcp.osDisk.diskType)
if [ -z "${control_plane_disk_type}" ]; then
  control_plane_disk_type=$(yq-go r "${SHARED_DIR}/install-config.yaml" platform.gcp.defaultMachinePlatform.osDisk.diskType)
fi
if [ -z "${control_plane_disk_type}" ]; then
  control_plane_disk_type="pd-ssd"
fi

## Try the validation
ret=0

readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,type)" | grep worker)
if [[ ${#disks[@]} == 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - Zero compute/worker node found."
else
  echo "$(date -u --rfc-3339=seconds) - Checking OS disk type of compute nodes..."
  for line in "${disks[@]}"; do
    name="${line%% *}"
    type="${line##* }"
    if [[ "${type}" != "${compute_disk_type}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Unexpected .type '${type}' for '${name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - Matched .type '${type}' for '${name}'."
    fi
  done
fi

readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,type)" | grep master)
if [[ ${#disks[@]} == 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to find control-plane node disk."
  ret=1
else
  echo "$(date -u --rfc-3339=seconds) - Checking OS disk type of control-plane nodes..."
  for line in "${disks[@]}"; do
    name="${line%% *}"
    type="${line##* }"
    if [[ "${type}" != "${control_plane_disk_type}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Unexpected .type '${type}' for '${name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - Matched .type '${type}' for '${name}'."
    fi
  done
fi

echo "Exit code: '${ret}'"
exit ${ret}
