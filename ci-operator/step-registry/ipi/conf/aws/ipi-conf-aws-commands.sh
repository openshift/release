#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]]; then
  # Hack to avoid importing arm64 release image by using an image override
  # Find a better way of doing this once https://issues.redhat.com/browse/DPTP-2265 is resolved
  if [[ -z "${ARM64_RELEASE_OVERRIDE}" ]]; then
    echo "ARM64_RELEASE_OVERRIDE is an empty string, exiting"
    exit 1
  fi
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${ARM64_RELEASE_OVERRIDE}
  echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  openshift-install version
  # end of hack
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '8 hours' --iso=minutes --utc)

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
mapfile -t INSTANCE_ZONES < <(aws --region "${REGION}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${master_type}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort -u)
# Generate availability zones based on these 2 criterias
mapfile -t ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
# Calculate the maximum number of availability zones from the region
MAX_ZONES_COUNT="${#ZONES[@]}"
# Save max zones count information to ${SHARED_DIR} for use in other scenarios
echo "${MAX_ZONES_COUNT}" >> "${SHARED_DIR}/maxzonescount"


ZONES_COUNT=${ZONES_COUNT:-2}
ZONES=("${ZONES[@]:0:${ZONES_COUNT}}")
ZONES_STR="[ "
ZONES_STR+=$(join_by , "${ZONES[@]}")
ZONES_STR+=" ]"
echo "AWS region: ${REGION} (zones: ${ZONES_STR})"

cat >> "${CONFIG}" << EOF
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
      type: ${master_type}
      zones: ${ZONES_STR}
compute:
- architecture: ${architecture}
  name: worker
  replicas: ${workers}
  platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
      zones: ${ZONES_STR}
EOF
