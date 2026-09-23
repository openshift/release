#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

mkdir -p terraform_quay_aws_rds && cd terraform_quay_aws_rds
cp ${SHARED_DIR}/terraform.tgz .
tar -xzvf terraform.tgz && ls

QUAY_AWS_S3_BUCKET=$(cat ${SHARED_DIR}/QUAY_AWS_S3_BUCKET)
QUAY_SUBNET_GROUP=$(cat ${SHARED_DIR}/QUAY_SUBNET_GROUP)
QUAY_SECURITY_GROUP=$(cat ${SHARED_DIR}/QUAY_SECURITY_GROUP)
echo "Start to destroy quay aws rds postgresql and s3 buckets ..."

#Destroy Quay Security Testing Host
export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
export TF_VAR_quay_subnet_group="${QUAY_SUBNET_GROUP}"
export TF_VAR_quay_security_group="${QUAY_SECURITY_GROUP}"
terraform --version
terraform init
terraform destroy -auto-approve || true
