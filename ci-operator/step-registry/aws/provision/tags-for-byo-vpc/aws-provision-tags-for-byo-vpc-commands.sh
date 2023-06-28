#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  echo "Using shared account"
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
else
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

REGION="${LEASED_RESOURCE}"

infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
vpc_id=$(head -n 1 ${SHARED_DIR}/vpc_id)
private_subnet_ids=$(yq-go r -j ${SHARED_DIR}/private_subnet_ids | jq -r '[ . | join(" ") ] | @csv' | sed "s/\"//g")

if [[ -z $vpc_id ]] || [[ -z $private_subnet_ids ]] || [[ -z $infra_id ]]; then
  echo "Error: Can not get VPC id or private subnets, exit"
  echo "vpc: $vpc_id, private_subnet_ids: $private_subnet_ids"
  exit 1
fi

echo "Adding tags for VPC: $vpc_id, tags: kubernetes.io/cluster/${infra_id}, value: shared."
aws --region $REGION ec2 create-tags --resources $vpc_id --tags Key=kubernetes.io/cluster/${infra_id},Value=shared

echo "Adding tags for private subnets:$private_subnet_ids, tags: kubernetes.io/role/internal-elb, value is empty."
aws --region $REGION ec2 create-tags --resources $private_subnet_ids --tags Key=kubernetes.io/role/internal-elb,Value=
