#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '8 hours' --iso=minutes --utc)

created_date=$(date --iso=minutes --utc)

function join_by { local IFS="$1"; shift; echo "$*"; }

REGION="${LEASED_RESOURCE}"
# BootstrapInstanceType gets its value from pkg/types/aws/defaults/platform.go
architecture="amd64"
arch_instance_type=m5
if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]]; then
  architecture="arm64"
  arch_instance_type=m6g
fi

BOOTSTRAP_NODE_TYPE=${arch_instance_type}.large

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi
master_type=null
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type=${arch_instance_type}.8xlarge
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type=${arch_instance_type}.4xlarge
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type=${arch_instance_type}.2xlarge
fi

# Generate working availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones | jq -r '.AvailabilityZones[] | select(.State == "available") | .ZoneName' | sort -u)
# Generate availability zones with OpenShift Installer required instance types

if [[ "${COMPUTE_NODE_TYPE}" == "${BOOTSTRAP_NODE_TYPE}" && "${COMPUTE_NODE_TYPE}" == "${master_type}" ]]; then ## all regions are the same 
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${master_type}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
elif [[ "${master_type}" == null && "${COMPUTE_NODE_TYPE}" == null  ]]; then ## two null regions
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${master_type}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
elif [[ "${master_type}" == null || "${COMPUTE_NODE_TYPE}" == null ]]; then ## one null region
  if [[ "${BOOTSTRAP_NODE_TYPE}" == "${COMPUTE_NODE_TYPE}" || "${BOOTSTRAP_NODE_TYPE}" == "${master_type}" || "${master_type}" == "${COMPUTE_NODE_TYPE}" ]]; then ## "one null region and duplicates"
    mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${master_type}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
  else ## "one null region and no duplicates"
    mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${master_type}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 2 ' | awk '{print $2}')
  fi 
elif [[ "${BOOTSTRAP_NODE_TYPE}" == "${COMPUTE_NODE_TYPE}" || "${BOOTSTRAP_NODE_TYPE}" == "${master_type}" || "${master_type}" == "${COMPUTE_NODE_TYPE}" ]]; then ## duplicates regions with no null region
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${master_type}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 2 ' | awk '{print $2}')
elif [[ "${BOOTSTRAP_NODE_TYPE}" != "${COMPUTE_NODE_TYPE}" && "${COMPUTE_NODE_TYPE}" != "${master_type}" ]]; then   # three different regions
  mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${master_type}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 3 ' | awk '{print $2}')
fi
# Generate availability zones based on these 2 criterias
mapfile -t ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
# Calculate the maximum number of availability zones from the region
MAX_ZONES_COUNT="${#ZONES[@]}"
# Save max zones count information to ${SHARED_DIR} for use in other scenarios
echo "${MAX_ZONES_COUNT}" >> "${SHARED_DIR}/maxzonescount"

existing_zones_setting=$(/tmp/yq r "${CONFIG}" 'controlPlane.platform.aws.zones')

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
      createdDate: ${created_date}
      updatedDate: ${created_date}
      expirationDate: ${expiration_date}
controlPlane:
  architecture: ${architecture}
  name: master
  platform:
    aws:
      type: ${master_type}
compute:
- architecture: ${architecture}
  name: worker
  replicas: ${workers}
  platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
EOF
/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
