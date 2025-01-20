#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create AWS S3 Storage Bucket
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_AWS_S3_BUCKET="quayprowsts$RANDOM"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)

mkdir -p QUAY_AWSSTS && cd QUAY_AWSSTS
cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}

variable "aws_bucket" {
  default = "quayawssts"
}
EOF

cat >>create_aws_bucket.tf <<EOF
provider "aws" {
  region = "us-east-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}

resource "aws_s3_bucket" " quayawssts" {
  bucket = var.aws_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" " quayawssts" {
  bucket = aws_s3_bucket. quayawssts.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls. quayawssts]

  bucket = aws_s3_bucket. quayawssts.id
  acl    = "private"
}
EOF

echo "quay aws s3 bucket name is ${QUAY_AWS_S3_BUCKET}"
export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
terraform init
terraform apply -auto-approve || true

#Share Terraform Var and Terraform Directory
echo "${QUAY_AWS_S3_BUCKET}" > ${SHARED_DIR}/QUAY_AWS_S3_BUCKET
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}
