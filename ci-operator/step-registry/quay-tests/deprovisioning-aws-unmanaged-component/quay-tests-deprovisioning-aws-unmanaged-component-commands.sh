#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE="quay_unmanaged_aws_terraform.tgz"

echo "Copy terraform files back from $SHARED_DIR"
mkdir -p terraform_quay_aws_unmanaged && cd terraform_quay_aws_unmanaged
cp ${SHARED_DIR}/$QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE .
tar -xzvf $QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE && ls

#Destroy Quay Security Testing Host
echo "Start to destroy quay aws rds postgresql, redis ec2 instance ands3 buckets ..."
terraform --version
terraform init
terraform destroy -auto-approve || true
