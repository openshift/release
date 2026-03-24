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
  # shellcheck disable=SC2178
  local -n ZONES=$1

  if [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: Filtering zones by the exclusion pattern '${ZONES_EXCLUSION_PATTERN}'"
    mapfile -t AVAILABILITY_ZONES < <(gcloud compute zones list --filter="region:${GCP_REGION} AND status:UP" --format='value(name)' | grep -v "${ZONES_EXCLUSION_PATTERN}")
  else
    mapfile -t AVAILABILITY_ZONES < <(gcloud compute zones list --filter="region:${GCP_REGION} AND status:UP" --format='value(name)')
  fi
  
  ZONES=("${AVAILABILITY_ZONES[@]}")
  echo "$(date -u --rfc-3339=seconds) - INFO: GCP region: ${GCP_REGION} (zones: ${ZONES[*]})"
}

function join_by { local IFS="$1"; shift; echo "$*"; }

function get_zones_by_machine_type() {
  local machine_type=$1
  # shellcheck disable=SC2178
  local -n ZONES=$2

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
  
  ZONES=("${AVAILABILITY_ZONES[@]}")
  echo "$(date -u --rfc-3339=seconds) - INFO: [${machine_type}] GCP region: ${GCP_REGION} (zones: ${ZONES[*]})"
}

# Function to get intersection or fallback
# Updates the first array (target) with intersection or fallback logic
function array_intersection_or_fallback() {
  local -n target_array=$1
  local -n source_array=$2

  # If target_array is empty, use source_array
  if [ ${#target_array[@]} -eq 0 ]; then
    target_array=("${source_array[@]}")
    return
  fi

  # If source_array is empty, keep target_array as is
  if [ ${#source_array[@]} -eq 0 ]; then
    return
  fi

  # Both arrays have elements, find intersection
  local result=()
  for elem1 in "${target_array[@]}"; do
    for elem2 in "${source_array[@]}"; do 
      if [ "$elem1" = "$elem2" ]; then
        result+=("$elem1")
        break 
      fi
    done
  done
  target_array=("${result[@]}")
}

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GOOGLE_PROJECT_ID=$(jq -r .project_id ${GCP_SHARED_CREDENTIALS_FILE})
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

# As a temporary workaround of https://redhat.atlassian.net/browse/OCPBUGS-78431, 
# ensure the compute & controlPlane machines will be deployed into the same set of zones. 
# the intersection of ZONES_ARRAY1 and ZONES_ARRAY2
CANDIDATE_ZONES_ARRAY=()

# compute/worker zones string, e.g. '[us-central1-a us-central1-b]'
ZONES_STR1=""
# compute/worker zones array, e.g. (us-central1-a us-central1-b)
ZONES_ARRAY1=()

# control-plane zones string, e.g. '[us-central1-b us-central1-c]'
ZONES_STR2=""
# control-plane zones array, e.g. (us-central1-b us-central1-c)
ZONES_ARRAY2=()

# Get compute/worker machine type
MACHINE_TYPE1=""
if [[ -n "${COMPUTE_NODE_TYPE}" ]]; then
  MACHINE_TYPE1="${COMPUTE_NODE_TYPE}"
else
  echo "$(date -u --rfc-3339=seconds) - INFO: Extracting compute node type from install-config"
  MACHINE_TYPE1=$(yq-go r "${CONFIG}" compute[0].platform.gcp.type)
  if [[ -z "${MACHINE_TYPE1}" ]]; then
    MACHINE_TYPE1=$(yq-go r "${CONFIG}" platform.gcp.defaultMachinePlatform.type)
  fi
fi
echo "$(date -u --rfc-3339=seconds) - INFO: compute/worker machine type is '${MACHINE_TYPE1}'"

# Get control-plane machine type
MACHINE_TYPE2=""
if [[ -n "${CONTROL_PLANE_NODE_TYPE}" ]]; then
  MACHINE_TYPE2="${CONTROL_PLANE_NODE_TYPE}"
else
  echo "$(date -u --rfc-3339=seconds) - INFO: Extracting control-plane node type from install-config"
  MACHINE_TYPE2=$(yq-go r "${CONFIG}" controlPlane.platform.gcp.type)
  if [[ -z "${MACHINE_TYPE2}" ]]; then
    MACHINE_TYPE2=$(yq-go r "${CONFIG}" platform.gcp.defaultMachinePlatform.type)
  fi
fi
echo "$(date -u --rfc-3339=seconds) - INFO: control-plane machine type is '${MACHINE_TYPE2}'"

if [[ -z "${COMPUTE_ZONES}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: COMPUTE_ZONES unspecified, getting the candidate zones by compute/worker machine type '${MACHINE_TYPE1}'"
  get_zones_by_machine_type "${MACHINE_TYPE1}" ZONES_ARRAY1

  if [[ ${#ZONES_ARRAY1[@]} -eq 0 ]] && [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: Found no zone for machine type '${MACHINE_TYPE1}', possibly a custom machine type. Filtering among all zones instead..."
    get_zones_from_region ZONES_ARRAY1
  fi
  echo "$(date -u --rfc-3339=seconds) - INFO: As a temporary workaround of https://redhat.atlassian.net/browse/OCPBUGS-78431, ensure the zones of compute & controlPlane machines are the same"
  array_intersection_or_fallback CANDIDATE_ZONES_ARRAY ZONES_ARRAY1
fi

if [[ -z "${CONTROL_PLANE_ZONES}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: CONTROL_PLANE_ZONES unspecified, getting the candidate zones by control-plane machine type '${MACHINE_TYPE2}'"
  get_zones_by_machine_type "${MACHINE_TYPE2}" ZONES_ARRAY2

  if [[ ${#ZONES_ARRAY2[@]} -eq 0 ]] && [[ -n "${ZONES_EXCLUSION_PATTERN}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: Found no zone for machine type '${MACHINE_TYPE2}', possibly a custom machine type. Filtering among all zones instead..."
    get_zones_from_region ZONES_ARRAY2
  fi
  echo "$(date -u --rfc-3339=seconds) - INFO: As a temporary workaround of https://redhat.atlassian.net/browse/OCPBUGS-78431, ensure the zones of compute & controlPlane machines are the same"
  array_intersection_or_fallback  CANDIDATE_ZONES_ARRAY ZONES_ARRAY2
fi

if [[ ${#CANDIDATE_ZONES_ARRAY[@]} -gt 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: Shuffle zones randomly to spread load across zones instead of always picking alphabetically first"
  mapfile -t CANDIDATE_ZONES_ARRAY < <(printf '%s\n' "${CANDIDATE_ZONES_ARRAY[@]}" | shuf)
  echo "$(date -u --rfc-3339=seconds) - INFO: Take the first ${ZONES_COUNT} zones"
  CANDIDATE_ZONES_ARRAY=("${CANDIDATE_ZONES_ARRAY[@]:0:${ZONES_COUNT}}")
fi

if [[ -n "${COMPUTE_ZONES}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: COMPUTE_ZONES specified, '${COMPUTE_ZONES}', using it for compute/worker machines"
  ZONES_STR1="${COMPUTE_ZONES}"
elif [[ ${#CANDIDATE_ZONES_ARRAY[@]} -gt 0 ]]; then
  ZONES_STR1="[ $(join_by , "${CANDIDATE_ZONES_ARRAY[@]}") ]"
fi

if [[ -n "${ZONES_STR1}" ]]; then
  cat >> "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      zones: ${ZONES_STR1}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
else
  echo "$(date -u --rfc-3339=seconds) - INFO: Skipped setting zones for compute"
fi

if [[ -n "${CONTROL_PLANE_ZONES}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: CONTROL_PLANE_ZONES specified, '${CONTROL_PLANE_ZONES}', using it for control-plane machines"
  ZONES_STR2="${CONTROL_PLANE_ZONES}"
elif [[ ${#CANDIDATE_ZONES_ARRAY[@]} -gt 0 ]]; then
  ZONES_STR2="[ $(join_by , "${CANDIDATE_ZONES_ARRAY[@]}") ]"
fi

if [[ -n "${ZONES_STR2}" ]]; then
  cat >> "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    gcp:
      zones: ${ZONES_STR2}
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
