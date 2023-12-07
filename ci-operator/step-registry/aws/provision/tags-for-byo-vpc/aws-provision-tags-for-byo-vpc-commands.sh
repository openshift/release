#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
private_subnet_ids=$(yq-go r -j ${SHARED_DIR}/private_subnet_ids | jq -r '[ . | join(" ") ] | @csv' | sed "s/\"//g")

if [[ -z $vpc_id ]] || [[ -z $private_subnet_ids ]] || [[ -z $infra_id ]] || [[ "${infra_id}" == "null" ]]; then
  echo "Error: Can not get VPC id or private subnets, exit"
  echo "vpc: $vpc_id, private_subnet_ids: $private_subnet_ids"
  exit 1
fi

echo "Adding tags for VPC: $vpc_id, tags: kubernetes.io/cluster/${infra_id}, value: shared."
aws --region $REGION ec2 create-tags --resources $vpc_id --tags Key=kubernetes.io/cluster/${infra_id},Value=shared

echo "Adding tags for private subnets:$private_subnet_ids, tags: kubernetes.io/role/internal-elb, value is empty."
aws --region $REGION ec2 create-tags --resources $private_subnet_ids --tags Key=kubernetes.io/role/internal-elb,Value=
