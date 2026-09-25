#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${LEASED_RESOURCE}

CLUSTER_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
STACK_NAME="${CLUSTER_PREFIX}-vpc"

install_dir1=$(mktemp -d)
install_dir2=$(mktemp -d)

cp "${SHARED_DIR}/cluster-1-metadata.json" ${install_dir1}/metadata.json
cp "${SHARED_DIR}/cluster-2-metadata.json" ${install_dir2}/metadata.json

echo "Destroying cluster 1"
openshift-install destroy cluster --dir $install_dir1

echo "Destroying cluster 2"
openshift-install destroy cluster --dir $install_dir2

echo "Deleting VPC stack"
aws --region $REGION cloudformation delete-stack --stack-name "${STACK_NAME}" &
wait "$!"
aws --region $REGION cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Deleted VPC."
