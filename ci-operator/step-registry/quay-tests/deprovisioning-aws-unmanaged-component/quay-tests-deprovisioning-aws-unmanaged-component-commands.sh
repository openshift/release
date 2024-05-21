#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE="QUAY_UNMANAGED_AWS_TERRAFORM.tgz"

echo "Copy terraform files back from $SHARED_DIR"
mkdir -p terraform_quay_aws_unmanaged && cd terraform_quay_aws_unmanaged
cp ${SHARED_DIR}/$QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE .
tar -xzvf $QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE && ls

#Destroy Quay aws ec2 instance, rds postgres, s3 bucket
echo "Start to destroy quay aws rds postgresql, redis ec2 instance and s3 buckets ..."
terraform --version
terraform init
terraform destroy -auto-approve || true
