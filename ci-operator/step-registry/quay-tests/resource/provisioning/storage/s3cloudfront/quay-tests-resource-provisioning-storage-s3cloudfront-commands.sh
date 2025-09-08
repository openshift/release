#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# !!origin_path in aws_cloudfront_distribution must match storage_path in config.yaml

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
random=$RANDOM

#Create AWS S3 Bucket and CloudFront
QUAY_AWS_S3_CF_BUCKET="quayprowcf$random"

mkdir -p QUAY_S3CloundFront && cd QUAY_S3CloundFront
cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}

variable "aws_bucket" {
  default = "quays3cloudfront"
}

variable "quay_s3_origin_id" {
default = "quay_origin_id"
}
EOF

cat >>create_s3_cloudfront.tf <<EOF
provider "aws" {
  region = var.region
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}

#s3 bucket
resource "aws_s3_bucket" "quayawscf" {
  bucket = var.aws_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "quayawscf" {
  bucket = aws_s3_bucket.quayawscf.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

#Block public access, data distrbution with cloudFront
resource "aws_s3_bucket_public_access_block" "quayawscf" {
  bucket = aws_s3_bucket.quayawscf.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "quay_oac" {
  name                              = "\${aws_s3_bucket.quayawscf.id}.s3.\${var.region}.amazonaws.com"
  description                       = "OAC for Quay S3 access"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "allow_cloudfront" {
  bucket = aws_s3_bucket.quayawscf.id
  depends_on = [aws_cloudfront_distribution.quay_s3_distribution]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        "Sid"       : "AllowBucketRead"
        "Effect"    : "Allow"
        "Principal" : {
          "Service": "cloudfront.amazonaws.com"
        }
        "Action" : ["s3:GetObject"],
        "Resource" : "\${aws_s3_bucket.quayawscf.arn}/*",
        "Condition" : {
          "StringEquals" : {
            "AWS:SourceArn" : "\${aws_cloudfront_distribution.quay_s3_distribution.arn}"
          }
        }
      },
      {
          "Sid"     :   "AllowBucketListing"
          "Effect": "Allow",
          "Principal": {
              "Service": "cloudfront.amazonaws.com"
          },
          "Action": "s3:ListBucket",
          "Resource": "\${aws_s3_bucket.quayawscf.arn}",
           "Condition": {
               "StringEquals": {
                   "AWS:SourceArn": "\${aws_cloudfront_distribution.quay_s3_distribution.arn}"
               }
           }
      }
    ]
  })
}

resource "aws_cloudfront_distribution" "quay_s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.quayawscf.bucket_regional_domain_name
    origin_id   = var.quay_s3_origin_id
    origin_path              = "/cloudfronts3/quayregistry"
    origin_access_control_id = aws_cloudfront_origin_access_control.quay_oac.id
 }
  comment = "Quay Prow CI CloudFront distribution for S3 bucket"
  enabled             = true

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = var.quay_s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
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


resource "aws_s3_bucket_cors_configuration" "quays3cros" {
  bucket = aws_s3_bucket.quayawscf.id

  cors_rule {
    allowed_headers = ["Authorization"]
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    expose_headers  = []
    max_age_seconds = 3000
  }

  cors_rule {
    allowed_headers = ["Content-Type","x-amz-acl","origin"]
    allowed_methods = ["PUT"]
    allowed_origins = ["*"]
    expose_headers  = []
    max_age_seconds = 3000
  }
}

output "Cloudfront_id" {
  value = aws_cloudfront_distribution.quay_s3_distribution.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.quay_s3_distribution.domain_name
}
EOF

echo "quay aws s3 bucket name is ${QUAY_AWS_S3_CF_BUCKET}"
export TF_VAR_aws_bucket="${QUAY_AWS_S3_CF_BUCKET}"
export TF_VAR_quay_s3_origin_id="quay_origin_id${random}"

terraform init
terraform apply -auto-approve || true

#Share Terraform Var and Terraform Directory
echo "$random"  > "${SHARED_DIR}/QUAY_AWS_CF_RANDOM"
echo "${QUAY_AWS_S3_CF_BUCKET}" > "${SHARED_DIR}/QUAY_AWS_S3_CF_BUCKET"

# trim quotes from terraform output
COLUDFRONT_ID=$(terraform output Cloudfront_id | tr -d '""' | tr -d '\n')
COLUDFRONT_DOMAIN=$(terraform output cloudfront_domain_name | tr -d '""' | tr -d '\n')

echo "${COLUDFRONT_ID}" > "${SHARED_DIR}/QUAY_S3_CLOUDFRONT_ID"
echo "${COLUDFRONT_DOMAIN}" > "${SHARED_DIR}/QUAY_CLOUDFRONT_DOMAIN"

tar -cvzf terraform.s3cf.tgz --exclude=".terraform" *
cp terraform.s3cf.tgz "${SHARED_DIR}/"
