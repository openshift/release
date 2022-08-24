#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '8 hours' --iso=minutes --utc)

function join_by { local IFS="$1"; shift; echo "$*"; }

REGION="${LEASED_RESOURCE}"
# BootstrapInstanceType gets its value from pkg/types/aws/defaults/platform.go
architecture=${OCP_ARCH:-"amd64"}
arch_instance_type=m6i
if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]]; then
  architecture="arm64"
fi

if [[ x"${architecture}" == x"arm64" ]]; then
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

existing_zones_setting=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.zones')

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
  yq-go m -x -i "${CONFIG}" "${PATCH}"
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
      type: ${master_type}
compute:
- architecture: ${architecture}
  name: worker
  replicas: ${workers}
  platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"

# custom rhcos ami for non-public regions
RHCOS_AMI=
if [ "$REGION" == "us-gov-west-1" ] || [ "$REGION" == "us-gov-east-1" ] || [ "$REGION" == "cn-north-1" ] || [ "$REGION" == "cn-northwest-1" ]; then
  # TODO: move repo to a more appropriate location
  curl -sL https://raw.githubusercontent.com/yunjiang29/ocp-test-data/main/coreos-for-non-public-regions/images.json -o /tmp/ami.json
  oc registry login
  # ocp_version=4.9 4.10 etc.
  ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
  RHCOS_AMI=$(jq -r .architectures.x86_64.images.aws.regions.\"${REGION}\".\"${ocp_version}\".image /tmp/ami.json)
  echo "RHCOS_AMI: $RHCOS_AMI, ocp_version: $ocp_version"
fi

if [ ! -z ${RHCOS_AMI} ]; then
  echo "patching rhcos ami to install-config.yaml"
  CONFIG_PATCH_AMI="${SHARED_DIR}/install-config-ami.yaml.patch"
  cat >> "${CONFIG_PATCH_AMI}" << EOF
platform:
  aws:
    amiID: ${RHCOS_AMI}
EOF
  yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH_AMI}"
  cp "${SHARED_DIR}/install-config-ami.yaml.patch" "${ARTIFACT_DIR}/"
fi


if [[ ${AWS_METADATA_SERVICE_AUTH} =~ ^(Required|Optional)$ ]]; then
  echo "setting up metadata auth in install-config.yaml. Set metadata service auth to: ${AWS_METADATA_SERVICE_AUTH}"
  METADATA_AUTH_PATCH="${SHARED_DIR}/install-config-metadata-auth.yaml.patch"

  cat > "${METADATA_AUTH_PATCH}" << EOF
controlPlane:
  platform:
    aws:
      metadataService:
        authentication: ${AWS_METADATA_SERVICE_AUTH}
compute:
- platform:
    aws:
      metadataService:
        authentication: ${AWS_METADATA_SERVICE_AUTH}
EOF

  yq-go m -x -i "${CONFIG}" "${METADATA_AUTH_PATCH}"
  cp "${METADATA_AUTH_PATCH}" "${ARTIFACT_DIR}/"
fi
