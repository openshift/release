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

if [[ -z "${CONTROL_PLANE_NODE_TYPE}" ]] && [[ -z "${COMPUTE_NODE_TYPE}" ]]; then
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

expected_control_plane_type="${CONTROL_PLANE_NODE_TYPE}"
expected_compute_type="${COMPUTE_NODE_TYPE}"

## Try the validation
ret=0

if [ -n "${expected_control_plane_type}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Checking machine type of control-plane nodes..."
  readarray -t machines < <(gcloud compute instances list --filter="name~${CLUSTER_NAME}" --format="table(name,machineType)" | grep master)
  for line in "${machines[@]}"; do
    machine_name="${line%% *}"
    machine_type="${line##* }"
    if [[ "${machine_type}" != "${expected_control_plane_type}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Unexpected .machineType '${machine_type}' for '${machine_name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - Matched .machineType '${machine_type}' for '${machine_name}'."
    fi
  done
fi

if [ -n "${expected_compute_type}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Checking machine type of compute nodes..."
  readarray -t machines < <(gcloud compute instances list --filter="name~${CLUSTER_NAME}" --format="table(name,machineType)" | grep worker)
  for line in "${machines[@]}"; do
    machine_name="${line%% *}"
    machine_type="${line##* }"
    if [[ "${machine_type}" != "${expected_compute_type}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Unexpected .machineType '${machine_type}' for '${machine_name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - Matched .machineType '${machine_type}' for '${machine_name}'."
    fi
  done
fi

exit ${ret}
