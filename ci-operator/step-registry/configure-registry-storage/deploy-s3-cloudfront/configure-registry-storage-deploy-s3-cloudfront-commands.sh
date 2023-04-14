#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script will deploy an aws s3 bucket and cloudfront distribution.
# It need deploy against aws platform.

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov) export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred;;
aws-c2s|aws-sc2s) export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_temp_creds;;
*) echo "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

AWS_ACCESS_KEY_ID=$(cat "${AWS_SHARED_CREDENTIALS_FILE}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2) && export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(cat "${AWS_SHARED_CREDENTIALS_FILE}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2) && export AWS_SECRET_ACCESS_KEY

if [[ ${AWS_ACCESS_KEY_ID} == "" ]] || [[ ${AWS_SECRET_ACCESS_KEY} == "" ]]; then
  echo "Did not find AWS credential, exit now"
  exit 1
fi

# get region to deploy new bucket
AWS_REGION=${LEASED_RESOURCE} && export AWS_REGION
NEW_BUCKET=$(head /dev/urandom | tr -dc a-z | head -c 10) && export NEW_BUCKET

# create file to deploy cloudfront using new bucket
cat >>"${SHARED_DIR}/create_s3_bucket_for_registry_storage.tf" <<EOF
provider "aws" {
  region = "${AWS_REGION}"
  access_key = "${AWS_ACCESS_KEY_ID}"
  secret_key = "${AWS_SECRET_ACCESS_KEY}"
}

resource "aws_s3_bucket" "ir_s3" {
  bucket = "${NEW_BUCKET}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ir_s3" {
  bucket = aws_s3_bucket.ir_s3.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "ir_s3_policy" {
  bucket = aws_s3_bucket.ir_s3.id
  policy = data.aws_iam_policy_document.ir_s3_policy_test.json
}

data "aws_iam_policy_document" "ir_s3_policy_test" {
  statement {
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "arn:aws:s3:::${NEW_BUCKET}/*",
    ]
  }
}

locals {
  s3_origin_id = "K3FZYAKDQYAWWP"
}

resource "aws_cloudfront_distribution" "ir_s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.ir_s3.bucket_regional_domain_name
    origin_id   = local.s3_origin_id

  }

  enabled             = true

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "cloudfront_id" {
  value = aws_cloudfront_distribution.ir_s3_distribution.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.ir_s3_distribution.domain_name
}
EOF

# deploy s3 new bucket and link it to cloudfront
cp "${SHARED_DIR}/create_s3_bucket_for_registry_storage.tf" /tmp && cd /tmp
terraform init
terraform apply -auto-approve
TF_OUTPUT=$(terraform output)
rm -rf /tmp/create_s3_bucket_for_registry_storage.tf || exit 1
CLOUDFRONT_DOMAIN_NAME=$(echo "${TF_OUTPUT}" | grep cloudfront_domain_name | tr -d ' ' | cut -d '"' -f 2) && export CLOUDFRONT_DOMAIN_NAME

# save terraform state file to destroy s3 bucket and cloudfront
tar -Jcf "${SHARED_DIR}/s3_cloudfront_terraform_state.tar.xz" terraform.tfstate

# create secert using private key for cloudfront
CLOUDFRONT_PRIVATE_KEY="${CLUSTER_PROFILE_DIR}/cloudfront-key"
if [[ -f "${CLOUDFRONT_PRIVATE_KEY}" ]]; then
  oc create secret generic cloudfront-secret --from-file=${CLOUDFRONT_PRIVATE_KEY} -n openshift-image-registry
else
  echo "Did not find compatible cloud provider cloudfront-key"
  exit 1
fi

# configure image registry to use cloudfront
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"storage":{"managementState":"Unmanaged","s3":{"bucket":"'"${NEW_BUCKET}"'","region":"'"${AWS_REGION}"'","cloudFront":{"baseURL":"https://'"${CLOUDFRONT_DOMAIN_NAME}"'","duration": "300s","keypairID":"K3FZYAKDQYAWWP","privateKey":{"key":"cloudfront-key","name":"cloudfront-secret"}}}}}}'

# wait image registry to redeploy with cloudfront
check_imageregistry_back_ready(){
  local result="" iter=10 period=60
  while [[ "${result}" != "TrueFalse" && $iter -gt 0 ]]; do
    sleep $period
    result=$(oc get co image-registry -o=jsonpath='{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}')
    (( iter -- ))
  done
  if [ "${result}" != "TrueFalse" ] ; then
    echo "Image registry failed to re-configure cloudfront, please check the below resources"
    oc describe pods -l docker-registry=default -n openshift-image-registry
    oc get config.image/cluster -o yaml
    return 1
  else
    echo "Image registry configured cloudfront successfully"
    return 0
  fi
}
check_imageregistry_back_ready || exit 1
