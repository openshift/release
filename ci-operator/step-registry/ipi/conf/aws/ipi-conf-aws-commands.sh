#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -sL https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

#export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

declare -g MASTER_FAMILY
declare -g MASTER_TYPE

CONFIG="${SHARED_DIR}/install-config.yaml"
REGION="${LEASED_RESOURCE}"

expiration_date=$(date -d '8 hours' --iso=minutes --utc)
existing_zones_setting=$(/tmp/yq r "${CONFIG}" 'controlPlane.platform.aws.zones')

function join_by { local IFS="$1"; shift; echo "$*"; }

function get_master_size {
  master_size=null
  if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
    master_size=4xlarge
  elif [[ "${SIZE_VARIANT}" == "large" ]]; then
    master_size=2xlarge
  elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
    master_size=xlarge
  fi
  echo ${master_size}
}

function set_MASTER_TYPE {
  local size
  size=$(get_master_size)
  if [[ "${size}" == "null" ]]; then
    MASTER_TYPE="${size}"
    return
  fi
  MASTER_TYPE="${MASTER_FAMILY}.$(get_master_size)"
}

function choose_preferred_type {
  local type_preferred
  local type_backup
  local zones_cnt_pref
  local zones_cnt_backup

  type_preferred="${1}.$(get_master_size)"
  type_backup="${2}.$(get_master_size)"

  if [[ ${existing_zones_setting} == "" ]]; then
    zones_cnt_pref=$(aws ec2 describe-instance-type-offerings \
      --region "${REGION}" \
      --location-type availability-zone \
      --filters Name=instance-type,Values=\"${type_preferred}\" \
      --query 'InstanceTypeOfferings[].Location' \
      --output json | jq -r '. | length')
    zones_cnt_backup=$(aws ec2 describe-instance-type-offerings \
      --region "${REGION}" \
      --location-type availability-zone \
      --filters Name=instance-type,Values=\"${type_backup}\" \
      --query 'InstanceTypeOfferings[].Location' \
      --output json | jq -r '. | length')
  else
    zones_expr=$(echo "${existing_zones_setting}" |jq -r '. | join("|")')
    zones_cnt_pref=$(aws ec2 describe-instance-type-offerings \
      --region "${REGION}" \
      --location-type availability-zone \
      --filters Name=instance-type,Values=\"${type_preferred}\" \
      --query 'InstanceTypeOfferings[].Location' \
      --output json \
      | jq -r ".[] |select(.? | match(\"${zones_expr}\"))" \
      | wc -l)
    zones_cnt_backup=$(aws ec2 describe-instance-type-offerings \
      --region "${REGION}" \
      --location-type availability-zone \
      --filters Name=instance-type,Values=\"${type_backup}\" \
      --query 'InstanceTypeOfferings[].Location' \
      --output json \
      | jq -r ".[] |select(.? | match(\"${zones_expr}\"))" \
      | wc -l)
  fi

  if [[ ${zones_cnt_pref} -ge ${zones_cnt_backup} ]]; then
    MASTER_FAMILY="${1}"
  else
    MASTER_FAMILY="${2}"
  fi
}

# BootstrapInstanceType gets its value from pkg/types/aws/defaults/platform.go
architecture="amd64"

# choose the preferred instance type depending of the availability on the
# region. If the availability is equal, the preferred will be chosen, otherwise
# the backup will be.
# See more in PreferredInstanceType() pkg/asset/machines/aws/instance_types.go
instance_preferred=m6i
instance_backup=m5
arch_instance_type=${instance_preferred}

if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]]; then
  architecture="arm64"
  arch_instance_type=m6g
  MASTER_FAMILY="${arch_instance_type}"
else
  choose_preferred_type "${instance_preferred}" "${instance_backup}"
  arch_instance_type=${MASTER_FAMILY}
  set_MASTER_TYPE
fi

BOOTSTRAP_NODE_TYPE=${arch_instance_type}.large

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi

# Generate working availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones | jq -r '.AvailabilityZones[] | select(.State == "available") | .ZoneName' | sort -u)
# Generate availability zones with OpenShift Installer required instance types

if [[ "${COMPUTE_NODE_TYPE}" == "${BOOTSTRAP_NODE_TYPE}" && "${COMPUTE_NODE_TYPE}" == "${MASTER_TYPE}" ]]; then ## all regions are the same 
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${MASTER_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
elif [[ "${MASTER_TYPE}" == null && "${COMPUTE_NODE_TYPE}" == null  ]]; then ## two null regions
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${MASTER_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
elif [[ "${MASTER_TYPE}" == null || "${COMPUTE_NODE_TYPE}" == null ]]; then ## one null region
  if [[ "${BOOTSTRAP_NODE_TYPE}" == "${COMPUTE_NODE_TYPE}" || "${BOOTSTRAP_NODE_TYPE}" == "${MASTER_TYPE}" || "${MASTER_TYPE}" == "${COMPUTE_NODE_TYPE}" ]]; then ## "one null region and duplicates"
    mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${MASTER_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
  else ## "one null region and no duplicates"
    mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${MASTER_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 2 ' | awk '{print $2}')
  fi 
elif [[ "${BOOTSTRAP_NODE_TYPE}" == "${COMPUTE_NODE_TYPE}" || "${BOOTSTRAP_NODE_TYPE}" == "${MASTER_TYPE}" || "${MASTER_TYPE}" == "${COMPUTE_NODE_TYPE}" ]]; then ## duplicates regions with no null region
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${MASTER_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 2 ' | awk '{print $2}')
elif [[ "${BOOTSTRAP_NODE_TYPE}" != "${COMPUTE_NODE_TYPE}" && "${COMPUTE_NODE_TYPE}" != "${MASTER_TYPE}" ]]; then   # three different regions
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${MASTER_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 3 ' | awk '{print $2}')
fi
# Generate availability zones based on these 2 criterias
mapfile -t ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
# Calculate the maximum number of availability zones from the region
MAX_ZONES_COUNT="${#ZONES[@]}"
# Save max zones count information to ${SHARED_DIR} for use in other scenarios
echo "${MAX_ZONES_COUNT}" >> "${SHARED_DIR}/maxzonescount"

if [[ ${existing_zones_setting} == "" ]]; then
  ZONES_COUNT=${ZONES_COUNT:-2}
  ZONES=("${ZONES[@]:0:${ZONES_COUNT}}")
  ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
  echo "AWS region: ${REGION} (zones: ${ZONES_STR})"
  PATCH="${SHARED_DIR}/install-config-zones.yaml.patch"
  cat > "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- platform:
    aws:
      zones: ${ZONES_STR}
EOF
  /tmp/yq m -x -i "${CONFIG}" "${PATCH}"
else
  echo "zones already set in install-config.yaml, skipped"
fi

PATCH="${SHARED_DIR}/install-config-common.yaml.patch"
cat > "${PATCH}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  aws:
    region: ${REGION}
    userTags:
      expirationDate: ${expiration_date}
controlPlane:
  architecture: ${architecture}
  name: master
  platform:
    aws:
      type: ${MASTER_TYPE}
compute:
- architecture: ${architecture}
  name: worker
  replicas: ${workers}
  platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
EOF
/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
