#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/zones.yaml.patch"

GCP_REGION="${LEASED_RESOURCE}"
ZONES_COUNT=3

echo "$(date -u --rfc-3339=seconds) - INFO: ZONES_EXCLUSION_PATTERN '${ZONES_EXCLUSION_PATTERN}'"
echo "$(date -u --rfc-3339=seconds) - INFO: COMPUTE_ZONES '${COMPUTE_ZONES}'"
echo "$(date -u --rfc-3339=seconds) - INFO: COMPUTE_NODE_TYPE '${COMPUTE_NODE_TYPE}'"
echo "$(date -u --rfc-3339=seconds) - INFO: CONTROL_PLANE_ZONES '${CONTROL_PLANE_ZONES}'"
echo "$(date -u --rfc-3339=seconds) - INFO: CONTROL_PLANE_NODE_TYPE '${CONTROL_PLANE_NODE_TYPE}'"

function get_zones_from_region() {
  if [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: Filtering zones by the exclusion pattern '${ZONES_EXCLUSION_PATTERN}'"
    mapfile -t AVAILABILITY_ZONES < <(gcloud compute zones list --filter="region:${GCP_REGION} AND status:UP" --format='value(name)' | grep -v "${ZONES_EXCLUSION_PATTERN}" | shuf)
  else
    mapfile -t AVAILABILITY_ZONES < <(gcloud compute zones list --filter="region:${GCP_REGION} AND status:UP" --format='value(name)' | shuf)
  fi
  
  echo "$(date -u --rfc-3339=seconds) - INFO: Take the first ${ZONES_COUNT} zones"
  ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
  ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
  echo "$(date -u --rfc-3339=seconds) - INFO: GCP region: ${GCP_REGION} (zones: ${ZONES_STR})"
}

function join_by { local IFS="$1"; shift; echo "$*"; }

function get_zones_by_machine_type() {
  local machine_type=$1

  if [[ -z "${machine_type}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: Nothing to do for empty machine type"
    return
  fi

  echo "$(date -u --rfc-3339=seconds) - INFO: Get all zones supporting the machine type '${machine_type}'"
  mapfile -t AVAILABILITY_ZONES < <(gcloud compute machine-types list --filter="zone~${GCP_REGION} AND name=${machine_type}" --format='value(zone)')
  if [[ ${#AVAILABILITY_ZONES[@]} -eq 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: Failed to find any zone in region '${GCP_REGION}' supporting the machine type '${machine_type}'"
    return
  fi
  echo "$(date -u --rfc-3339=seconds) - INFO: [${machine_type}] the initial AVAILABILITY_ZONES '${AVAILABILITY_ZONES[*]}'"
  
  if [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: Filtering zones by the exclusion pattern '${ZONES_EXCLUSION_PATTERN}'"
    local filtered_zones=()
    set +e
    for zone in "${AVAILABILITY_ZONES[@]}"; do
      echo "${zone}" | grep -q "${ZONES_EXCLUSION_PATTERN}"
      if [[ $? -ne 0 ]]; then
        filtered_zones+=("${zone}")
      else
        echo "$(date -u --rfc-3339=seconds) - INFO: Skipped zone '${zone}'"
      fi
    done
    set -e

    # Only use filtered zones if we found non-PATTERN-matching zones, otherwise use all zones
    if [[ ${#filtered_zones[@]} -gt 0 ]]; then
      AVAILABILITY_ZONES=("${filtered_zones[@]}")
    else
      echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find zones NOT matching the pattern, abort."
      exit 1
    fi
  fi
  
  echo "$(date -u --rfc-3339=seconds) - INFO: Shuffle zones randomly to spread load across zones instead of always picking alphabetically first"
  mapfile -t AVAILABILITY_ZONES < <(printf '%s\n' "${AVAILABILITY_ZONES[@]}" | shuf)
  
  echo "$(date -u --rfc-3339=seconds) - INFO: Take the first ${ZONES_COUNT} zones"
  ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
  ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
  echo "$(date -u --rfc-3339=seconds) - INFO: [${machine_type}] GCP region: ${GCP_REGION} (zones: ${ZONES_STR})"
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
MACHINE_TYPE=""
if [[ -n "${COMPUTE_ZONES}" ]]; then
  ZONES_STR="${COMPUTE_ZONES}"
elif [[ -n "${COMPUTE_NODE_TYPE}" ]]; then
  MACHINE_TYPE="${COMPUTE_NODE_TYPE}"
elif [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: Extracting compute node type from install-config"
  MACHINE_TYPE=$(yq-go r "${CONFIG}" compute[0].platform.gcp.type)
  if [[ -z "${MACHINE_TYPE}" ]]; then
    MACHINE_TYPE=$(yq-go r "${CONFIG}" platform.gcp.defaultMachinePlatform.type)
  fi
fi
get_zones_by_machine_type "${MACHINE_TYPE}"
if [[ -z "${ZONES_STR}" ]] && [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: Found no zone for machine type '${MACHINE_TYPE}', possibly a custom machine type. Filtering among all zones instead..."
  get_zones_from_region
fi

if [[ -n "${ZONES_STR}" ]]; then
  cat >> "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      zones: ${ZONES_STR}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
else
  echo "$(date -u --rfc-3339=seconds) - INFO: Skipped setting zones for compute"
fi

ZONES_STR=""
MACHINE_TYPE=""
if [[ -n "${CONTROL_PLANE_ZONES}" ]]; then
  ZONES_STR="${CONTROL_PLANE_ZONES}"
elif [[ -n "${CONTROL_PLANE_NODE_TYPE}" ]]; then
  MACHINE_TYPE="${CONTROL_PLANE_NODE_TYPE}"
elif [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: Extracting control-plane node type from install-config"
  MACHINE_TYPE=$(yq-go r "${CONFIG}" controlPlane.platform.gcp.type)
  if [[ -z "${MACHINE_TYPE}" ]]; then
    MACHINE_TYPE=$(yq-go r "${CONFIG}" platform.gcp.defaultMachinePlatform.type)
  fi
fi
get_zones_by_machine_type "${MACHINE_TYPE}"
if [[ -z "${ZONES_STR}" ]] && [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: Found no zone for machine type '${MACHINE_TYPE}', possibly a custom machine type. Filtering among all zones instead..."
  get_zones_from_region
fi

if [[ -n "${ZONES_STR}" ]]; then
  cat >> "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    gcp:
      zones: ${ZONES_STR}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
else
  echo "$(date -u --rfc-3339=seconds) - INFO: Skipped setting zones for controlPlane"
fi

yq-go r "${CONFIG}" platform
yq-go r "${CONFIG}" compute
yq-go r "${CONFIG}" controlPlane

if [ -f "${PATCH}" ]; then
  rm "${PATCH}"
fi
