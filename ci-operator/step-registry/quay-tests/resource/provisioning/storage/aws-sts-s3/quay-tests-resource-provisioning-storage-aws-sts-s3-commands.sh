#!/bin/bash
# shellcheck disable=SC2154

set -o nounset
set -o errexit
set -o pipefail

#Create AWS S3 Storage Bucket
QUAY_AWS_STS_S3_BUCKET="quayprowsts$RANDOM"
echo $QUAY_AWS_STS_S3_BUCKET 

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

variable "aws_sts_role_name" {
default = "quay_prow_role"
}

variable "aws_sts_user_name" {
default = "quay_prow_automation"
}

EOF

cat >>create_aws_sts.tf <<EOF
provider "aws" {
  region = "us-east-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}

#s3 bucket
resource "aws_s3_bucket" "quayawssts" {
  bucket = var.aws_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "quayawssts" {
  bucket = aws_s3_bucket.quayawssts.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.quayawssts]

  bucket = aws_s3_bucket.quayawssts.id
  acl    = "private"
}

#sts user
resource "aws_iam_user" "quay" {
  name = var.aws_sts_user_name
  path = "/"
}

resource "aws_iam_access_key" "quay" {
  user    = aws_iam_user.quay.name
  depends_on = [aws_iam_user.quay]
}

#sts role
resource "aws_iam_role" "quay_ci_role" {

  name = var.aws_sts_role_name
  assume_role_policy = <<EOF2
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::301721915996:user/${aws_iam_user.quay.name}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF2
}

resource "aws_iam_role_policy_attachment" "policy_attachment" {

  role       = aws_iam_role.quay_ci_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"

}

output "role" {
  value = aws_iam_role.quay_ci_role.arn
}
output "accesskey" {
  sensitive = true
  value = aws_iam_access_key.quay.id
}
output "secretkey" {
  sensitive = true
  value = aws_iam_access_key.quay.secret
}

EOF

echo "quay aws s3 bucket name is ${QUAY_AWS_STS_S3_BUCKET}"
export TF_VAR_aws_bucket="${QUAY_AWS_STS_S3_BUCKET}"
export TF_VAR_aws_sts_role_name="quay_prow_role${RANDOM}"
export TF_VAR_aws_sts_user_name="quay_prow_automation${RANDOM}"
echo $TF_VAR_aws_sts_role_name

terraform init
terraform apply -auto-approve || true
terraform output role > sts_role_arn
terraform output accesskey > sts_accesskey
terraform output secretkey > sts_secretkey
cat sts_accesskey

#Share Terraform Var and Terraform Directory
echo "${QUAY_AWS_S3_BUCKET}" > "${SHARED_DIR}/QUAY_AWS_STS_S3_BUCKET"
terraform output role  > "${SHARED_DIR}/QUAY_AWS_STS_STS_ROLE"
terraform output accesskey  > "${SHARED_DIR}/QUAY_AWS_STS_STS_ACCESSKEY"


tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}
