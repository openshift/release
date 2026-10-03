#!/bin/bash
set -euo pipefail

# Provision an AWS S3 bucket for Quay object storage and publish a
# backend-agnostic storage contract file that the install-quay-external-storage
# step folds into the QuayRegistry config bundle. This is the S3 implementation
# of that contract; a sibling provision-storage-{gcs,azure} would write the same
# ${SHARED_DIR}/quay-storage-config.yaml with its own DISTRIBUTED_STORAGE_CONFIG
# driver block, leaving install-quay-external-storage unchanged.
#
# Security (CLAUDE.md): this script runs without `set -x`, so the AWS keys read
# below and written into the contract file are never traced into CI logs. The
# keys live only in ${SHARED_DIR} (inter-step channel), never echoed to stdout.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-provision-storage-s3"
mkdir -p "${ARTIFACT_DIR}"

S3_REGION="${QUAY_S3_REGION:-us-east-2}"
S3_HOST="${QUAY_S3_HOST:-s3.${S3_REGION}.amazonaws.com}"
S3_STORAGE_PATH="${QUAY_S3_STORAGE_PATH:-/quay}"

QUAY_AWS_ACCESS_KEY="$(cat /var/run/quay-qe-aws-secret/access_key)"
QUAY_AWS_SECRET_KEY="$(cat /var/run/quay-qe-aws-secret/secret_key)"
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

# S3 bucket names are globally unique; $RANDOM (0-32767) alone collides with
# leftover buckets sharing the quayprowci prefix, so mix in namespace + hash.
new_s3_bucket_name() {
  local suffix
  suffix="${NAMESPACE:-ns}-${UNIQUE_HASH:-$(date +%s)}-${RANDOM}-$(date +%s)"
  suffix="$(printf '%s' "${suffix}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  printf 'quayprowci-%s\n' "${suffix}"
}

mkdir -p QUAY_AWS && cd QUAY_AWS
cat >variables.tf <<EOF
variable "region" {
  default = "${S3_REGION}"
}

variable "aws_bucket" {
  default = "quayaws"
}
EOF

cat >create_aws_bucket.tf <<EOF
provider "aws" {
  region = "${S3_REGION}"
}

resource "aws_s3_bucket" "quayaws" {
  bucket = var.aws_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "quayaws" {
  bucket = aws_s3_bucket.quayaws.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.quayaws]

  bucket = aws_s3_bucket.quayaws.id
  acl    = "private"
}
EOF

terraform init
tf_apply_rc=1
QUAY_AWS_S3_BUCKET=""
for _ in 1 2 3 4 5; do
  QUAY_AWS_S3_BUCKET="$(new_s3_bucket_name)"
  echo "quay aws s3 bucket name is ${QUAY_AWS_S3_BUCKET}"
  export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
  tf_apply_rc=0
  terraform apply -auto-approve || tf_apply_rc=$?
  if [[ "${tf_apply_rc}" -eq 0 ]]; then
    break
  fi
  echo "terraform apply failed with exit code ${tf_apply_rc}; retrying with a new bucket name" >&2
  terraform destroy -auto-approve || true
done

# Share the bucket name and terraform state so quay-deprovision can destroy the
# bucket on both success and failure paths.
echo "${QUAY_AWS_S3_BUCKET}" > "${SHARED_DIR}/QUAY_AWS_S3_BUCKET"
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz "${SHARED_DIR}"

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

# Publish the backend-agnostic storage contract consumed by
# install-quay-external-storage. Written by redirect (never echoed) so the S3
# secret key does not reach the log.
cat >"${SHARED_DIR}/quay-storage-config.yaml" <<EOF
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - S3Storage
    - s3_bucket: ${QUAY_AWS_S3_BUCKET}
      storage_path: ${S3_STORAGE_PATH}
      s3_access_key: ${QUAY_AWS_ACCESS_KEY}
      s3_secret_key: ${QUAY_AWS_SECRET_KEY}
      host: ${S3_HOST}
      s3_region: ${S3_REGION}
EOF

echo "Wrote S3 storage contract to \${SHARED_DIR}/quay-storage-config.yaml for bucket ${QUAY_AWS_S3_BUCKET}."
