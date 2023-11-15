#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${COMPUTE_OSIMAGE}" == "" ]] && [[ "${CONTROL_PLANE_OSIMAGE}" == "" ]] && [[ "${DEFAULT_MACHINE_OSIMAGE}" == "" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Nothing to do, abort." && exit 0
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

## The expected OS image
url_prefix="https://www.googleapis.com/compute/v1/projects/"
expected_compute_image=""
if [ -n "${COMPUTE_OSIMAGE}" ]; then
  expected_compute_image="${url_prefix}${COMPUTE_OSIMAGE##*projects/}"
elif [ -n "${DEFAULT_MACHINE_OSIMAGE}" ]; then
  expected_compute_image="${url_prefix}${DEFAULT_MACHINE_OSIMAGE##*projects/}"
fi

expected_control_plane_image=""
if [ -n "${CONTROL_PLANE_OSIMAGE}" ]; then
  expected_control_plane_image="${url_prefix}${CONTROL_PLANE_OSIMAGE##*projects/}"
elif [ -n "${DEFAULT_MACHINE_OSIMAGE}" ]; then
  expected_control_plane_image="${url_prefix}${DEFAULT_MACHINE_OSIMAGE##*projects/}"
fi

## Try the validation
ret=0

if [ -n "${expected_compute_image}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Checking OS images of compute nodes..."
  readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,sourceImage)" | grep worker)
  for line in "${disks[@]}"; do
    name="${line%% *}"
    source_image="${line##* }"
    if [[ "${source_image}" != "${expected_compute_image}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Unexpected .sourceImage '${source_image}' for '${name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - Matched .sourceImage '${source_image}' for '${name}'."
    fi
  done
fi

if [ -n "${expected_control_plane_image}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Checking OS images of control-plane nodes..."
  readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,sourceImage)" | grep master)
  for line in "${disks[@]}"; do
    name="${line%% *}"
    source_image="${line##* }"
    if [[ "${source_image}" != "${expected_control_plane_image}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Unexpected .sourceImage '${source_image}' for '${name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - Matched .sourceImage '${source_image}' for '${name}'."
    fi
  done
fi

popd
exit ${ret}
