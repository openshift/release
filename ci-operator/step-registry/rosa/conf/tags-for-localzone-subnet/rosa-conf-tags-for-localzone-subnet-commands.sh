#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

REGION="${LEASED_RESOURCE}"
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi


infra_id=$(head -n 1 ${SHARED_DIR}/infra_id)

LOCALZONE_SUBNET_FILE="${SHARED_DIR}/edge_zone_subnet_id"
if [[ -e "${LOCALZONE_SUBNET_FILE}" ]]; then
  localzone_subnet_id=$(head -n 1 "${LOCALZONE_SUBNET_FILE}")
  echo "Adding tags for localzon subnets$localzone_subnet_id, tags: kubernetes.io/cluster/${infra_id}, value is shared."
  aws --region $REGION ec2 create-tags --resources $localzone_subnet_id --tags Key=kubernetes.io/cluster/${infra_id},Value=shared
fi
