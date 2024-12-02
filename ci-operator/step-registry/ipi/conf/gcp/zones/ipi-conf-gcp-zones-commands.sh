#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/zones.yaml.patch"

GCP_REGION="${LEASED_RESOURCE}"
ZONES_COUNT=3

function join_by { local IFS="$1"; shift; echo "$*"; }

function get_zones_by_machine_type() {
  local machine_type=$1

  mapfile -t AVAILABILITY_ZONES < <(gcloud compute machine-types list --filter="zone~${GCP_REGION} AND name=${machine_type}" --format='value(zone)' | sort)
  ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
  ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
  echo "[${machine_type}] GCP region: ${GCP_REGION} (zones: ${ZONES_STR})"
}

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GOOGLE_PROJECT_ID=$(jq -r .project_id ${GCP_SHARED_CREDENTIALS_FILE})
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

ZONES_STR=""
if [[ -n "${COMPUTE_ZONES}" ]]; then
  ZONES_STR="${COMPUTE_ZONES}"
elif [[ -n "${COMPUTE_NODE_TYPE}" ]]; then
  get_zones_by_machine_type "${COMPUTE_NODE_TYPE}"
fi
if [[ -n "${ZONES_STR}" ]]; then
  cat >> "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      zones: ${ZONES_STR}
EOF
fi

ZONES_STR=""
if [[ -n "${CONTROL_PLANE_ZONES}" ]]; then
  ZONES_STR="${CONTROL_PLANE_ZONES}"
elif [[ -n "${CONTROL_PLANE_NODE_TYPE}" ]]; then
  get_zones_by_machine_type "${CONTROL_PLANE_NODE_TYPE}"
fi  
if [[ -n "${ZONES_STR}" ]]; then
  cat >> "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    gcp:
      zones: ${ZONES_STR}
EOF
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" compute
yq-go r "${CONFIG}" controlPlane

rm "${PATCH}"
