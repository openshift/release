#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CONFIG="${SHARED_DIR}/install-config.yaml"
az_file="${SHARED_DIR}/availability_zones"
sg_file="${SHARED_DIR}/security_groups"

if [ ! -f "${az_file}" ]; then
    availability_zones="$(aws --region "${REGION}" ec2 describe-availability-zones | jq -r '.AvailabilityZones[] | select(.State == "available") | .ZoneName' | sort -u)"
    echo "${availability_zones}" > ${az_file}
fi
echo -e "AZs: $(cat ${az_file})"

aws_subnet="$(yq-go r "${CONFIG}" 'platform.aws.subnets[0]')"
metadata_name="$(yq-go r "${CONFIG}" 'metadata.name')"
vpc_id="$(aws --region "${REGION}" ec2 describe-subnets --subnet-ids "${aws_subnet}" | jq -r '.[][0].VpcId')"
echo "Using vpc_id: ${vpc_id}"

security_group=$(aws ec2 create-security-group --region ${REGION} --description 'CI custom security groups' --group-name "${metadata_name}-sg"  --vpc-id ${vpc_id} --output text)
echo "${security_group}" > "${sg_file}"
echo "Security Group: ${security_group}"

CONFIG_PATCH="${SHARED_DIR}/install-config-security-groups.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
compute:
- platform:
    aws:
      additionalSecurityGroupIDs: [$(cat "${sg_file}")]
controlPlane:
  platform:
    aws:
      additionalSecurityGroupIDs: [$(cat "${sg_file}")]
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
