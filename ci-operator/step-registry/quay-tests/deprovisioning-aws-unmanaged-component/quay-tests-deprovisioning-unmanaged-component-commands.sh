#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE="quay_unmanaged_aws_terraform.tgz"
echo "omr secret"
# ls -l /var/run/quay-qe-omr-secret/
mkdir -p terraform_quay_aws_unmanaged && cd terraform_quay_aws_unmanaged
cp ${SHARED_DIR}/$QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE .
tar -xzvf $QUAY_UNMANAGED_AWS_TERRAFORM_PACKAGE && ls

# QUAY_AWS_S3_BUCKET=$(cat ${SHARED_DIR}/QUAY_AWS_S3_BUCKET)
# QUAY_SUBNET_GROUP=$(cat ${SHARED_DIR}/QUAY_SUBNET_GROUP)
# QUAY_SECURITY_GROUP=$(cat ${SHARED_DIR}/QUAY_SECURITY_GROUP)
echo "Sleep 10m..."

#Destroy Quay Security Testing Host
# export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
# export TF_VAR_quay_subnet_group="${QUAY_SUBNET_GROUP}"
# export TF_VAR_quay_security_group="${QUAY_SECURITY_GROUP}"
sleep 6000
echo "Start to destroy quay aws rds postgresql and s3 buckets ..."
terraform --version
terraform init
terraform destroy -auto-approve || true
