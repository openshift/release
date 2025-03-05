#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=${REGION:-$LEASED_RESOURCE}

if [[ -e ${SHARED_DIR}/metadata.json ]]; then
  # for OCP
  echo "Reading infra id from file metadata.json"
  infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
elif [[ -e ${SHARED_DIR}/infra_id ]]; then
  # for ManagedCluster, e.g. ROSA
  echo "Reading infra id from file infra_id"
  infra_id=$(head -n 1 ${SHARED_DIR}/infra_id)
else
  echo "Error: No infra id found, exit now"
  exit 1
fi

echo "infra_id: $infra_id"
vpc_id=$(head -n 1 ${SHARED_DIR}/vpc_id)

if [[ "${OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY}" == "true" ]]; then
    subnet_ids=$(yq-go r -j ${SHARED_DIR}/public_subnet_ids | jq -r '[ . | join(" ") ] | @csv' | sed "s/\"//g")
else
    subnet_ids=$(yq-go r -j ${SHARED_DIR}/private_subnet_ids | jq -r '[ . | join(" ") ] | @csv' | sed "s/\"//g")
fi

if [[ -z $vpc_id ]] || [[ -z $subnet_ids ]] || [[ -z $infra_id ]] || [[ "${infra_id}" == "null" ]]; then
  echo "Error: Can not get VPC id or private subnets, exit"
  echo "vpc: $vpc_id, subnet_ids: $subnet_ids"
  exit 1
fi

echo "Adding tags for VPC: $vpc_id, tags: kubernetes.io/cluster/${infra_id}, value: shared."
aws --region $REGION ec2 create-tags --resources $vpc_id --tags Key=kubernetes.io/cluster/${infra_id},Value=shared

echo "Adding tags for subnets:$subnet_ids, tags: kubernetes.io/role/internal-elb, value is empty."
aws --region $REGION ec2 create-tags --resources $subnet_ids --tags Key=kubernetes.io/role/internal-elb,Value=

if [[ ${ENABLE_AWS_EDGE_ZONE} == "yes" ]] && [[ ${EDGE_ZONE_TYPES} == "outpost" ]]; then
  edge_zone_public_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_public_subnet_id")
  edge_zone_private_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_private_subnet_id")
  
  # private id
  aws --region $REGION ec2 create-tags --resources $edge_zone_private_subnet_id --tags Key=kubernetes.io/role/internal-elb,Value=1

  # public id
  aws --region $REGION ec2 create-tags --resources $edge_zone_public_subnet_id --tags Key=kubernetes.io/role/elb,Value=1
fi
