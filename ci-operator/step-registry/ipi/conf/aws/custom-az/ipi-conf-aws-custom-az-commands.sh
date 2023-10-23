#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
CONFIG="${SHARED_DIR}/install-config.yaml"

function join_by { local IFS="$1"; shift; echo "$*"; }

mapfile -t AVAILABILITY_ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones --filter Name=state,Values=available Name=zone-type,Values=availability-zone | jq -r '.AvailabilityZones[].ZoneName' | sort -u)
ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
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
