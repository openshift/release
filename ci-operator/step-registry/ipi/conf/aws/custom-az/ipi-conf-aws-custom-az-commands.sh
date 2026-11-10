#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
CONFIG="${SHARED_DIR}/install-config.yaml"

function join_by { local IFS="$1"; shift; echo "$*"; }

if [[ -n "${AVAILABILITY_ZONES}" ]]; then
  mapfile -t ZONES < <(tr ',' '\n' <<< "${AVAILABILITY_ZONES}" | grep "^${REGION}[a-z]$" || true)
  if [[ ${#ZONES[@]} -eq 0 ]]; then
    echo "ERROR: no zones in AVAILABILITY_ZONES match region ${REGION}" >&2
    exit 1
  fi
else
  mapfile -t ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones --filter Name=state,Values=available Name=zone-type,Values=availability-zone | jq -r '.AvailabilityZones[].ZoneName' | sort -u)
  ZONES=("${ZONES[@]:0:${ZONES_COUNT}}")
fi
ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
echo "AWS region: ${REGION} (zones: ${ZONES_STR})"

CONFIG_PATCH="${SHARED_DIR}/install-config-zones.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- platform:
    aws:
      zones: ${ZONES_STR}
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
