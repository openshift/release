#!/bin/bash
set -euo pipefail

# Provision two AWS S3 buckets in two regions for Quay geo-replication.
# This script runs without set -x so AWS keys are never traced into CI logs.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-georep-provision-storage"
mkdir -p "${ARTIFACT_DIR}"

REGION_PRIMARY="${QUAY_GEOREP_REGION_PRIMARY:-us-east-1}"
REGION_SECONDARY="${QUAY_GEOREP_REGION_SECONDARY:-us-west-2}"
S3_STORAGE_PATH="${QUAY_S3_STORAGE_PATH:-/quay}"

QUAY_AWS_ACCESS_KEY="$(cat /var/run/quay-qe-aws-secret/access_key)"
QUAY_AWS_SECRET_KEY="$(cat /var/run/quay-qe-aws-secret/secret_key)"
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

new_s3_bucket_name() {
  local suffix
  suffix="${NAMESPACE:-ns}-${UNIQUE_HASH:-$(date +%s)}-${RANDOM}-$(date +%s)"
  suffix="$(printf '%s' "${suffix}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  printf 'quaygeorepci-%s\n' "${suffix}" | cut -c1-63
}

WORKDIR="$(mktemp -d)"
cd "${WORKDIR}"

cat >main.tf <<'TFEOF'
variable "region_primary" {}
variable "region_secondary" {}
variable "bucket_primary" {}
variable "bucket_secondary" {}

provider "aws" {
  alias  = "primary"
  region = var.region_primary
}

provider "aws" {
  alias  = "secondary"
  region = var.region_secondary
}

resource "aws_s3_bucket" "primary" {
  provider      = aws.primary
  bucket        = var.bucket_primary
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "primary" {
  provider = aws.primary
  bucket   = aws_s3_bucket.primary.id
  rule { object_ownership = "BucketOwnerPreferred" }
}

resource "aws_s3_bucket_acl" "primary" {
  provider   = aws.primary
  depends_on = [aws_s3_bucket_ownership_controls.primary]
  bucket     = aws_s3_bucket.primary.id
  acl        = "private"
}

resource "aws_s3_bucket" "secondary" {
  provider      = aws.secondary
  bucket        = var.bucket_secondary
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.secondary.id
  rule { object_ownership = "BucketOwnerPreferred" }
}

resource "aws_s3_bucket_acl" "secondary" {
  provider   = aws.secondary
  depends_on = [aws_s3_bucket_ownership_controls.secondary]
  bucket     = aws_s3_bucket.secondary.id
  acl        = "private"
}
TFEOF

terraform init

BUCKET_PRIMARY="$(new_s3_bucket_name)"
BUCKET_SECONDARY="$(new_s3_bucket_name)"

tf_apply_rc=1
for _ in 1 2 3 4 5; do
  BUCKET_PRIMARY="$(new_s3_bucket_name)"
  BUCKET_SECONDARY="$(new_s3_bucket_name)"
  echo "Primary bucket: ${BUCKET_PRIMARY} (${REGION_PRIMARY})"
  echo "Secondary bucket: ${BUCKET_SECONDARY} (${REGION_SECONDARY})"
  export TF_VAR_region_primary="${REGION_PRIMARY}"
  export TF_VAR_region_secondary="${REGION_SECONDARY}"
  export TF_VAR_bucket_primary="${BUCKET_PRIMARY}"
  export TF_VAR_bucket_secondary="${BUCKET_SECONDARY}"
  tf_apply_rc=0
  terraform apply -auto-approve || tf_apply_rc=$?
  if [[ "${tf_apply_rc}" -eq 0 ]]; then
    break
  fi
  echo "terraform apply failed (rc=${tf_apply_rc}); retrying" >&2
  terraform destroy -auto-approve || true
done

printf '%s' "${BUCKET_PRIMARY}" > "${SHARED_DIR}/QUAY_GEOREP_S3_BUCKET_PRIMARY"
printf '%s' "${BUCKET_SECONDARY}" > "${SHARED_DIR}/QUAY_GEOREP_S3_BUCKET_SECONDARY"
printf '%s' "${REGION_PRIMARY}" > "${SHARED_DIR}/QUAY_GEOREP_REGION_PRIMARY"
printf '%s' "${REGION_SECONDARY}" > "${SHARED_DIR}/QUAY_GEOREP_REGION_SECONDARY"
tar -czf "${SHARED_DIR}/terraform-georep-storage.tgz" --exclude=".terraform" -- *

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

S3_HOST_PRIMARY="s3.${REGION_PRIMARY}.amazonaws.com"
S3_HOST_SECONDARY="s3.${REGION_SECONDARY}.amazonaws.com"

cat >"${SHARED_DIR}/quay-storage-config.yaml" <<EOF
FEATURE_STORAGE_REPLICATION: true
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - ${REGION_PRIMARY}
  - ${REGION_SECONDARY}
DISTRIBUTED_STORAGE_PREFERENCE:
  - ${REGION_PRIMARY}
  - ${REGION_SECONDARY}
DISTRIBUTED_STORAGE_CONFIG:
  ${REGION_PRIMARY}:
    - S3Storage
    - s3_bucket: ${BUCKET_PRIMARY}
      storage_path: ${S3_STORAGE_PATH}
      s3_access_key: ${QUAY_AWS_ACCESS_KEY}
      s3_secret_key: ${QUAY_AWS_SECRET_KEY}
      host: ${S3_HOST_PRIMARY}
      s3_region: ${REGION_PRIMARY}
  ${REGION_SECONDARY}:
    - S3Storage
    - s3_bucket: ${BUCKET_SECONDARY}
      storage_path: ${S3_STORAGE_PATH}
      s3_access_key: ${QUAY_AWS_ACCESS_KEY}
      s3_secret_key: ${QUAY_AWS_SECRET_KEY}
      host: ${S3_HOST_SECONDARY}
      s3_region: ${REGION_SECONDARY}
EOF

echo "Wrote geo-rep storage contract to \${SHARED_DIR}/quay-storage-config.yaml"
echo "  Primary: ${BUCKET_PRIMARY} in ${REGION_PRIMARY}"
echo "  Secondary: ${BUCKET_SECONDARY} in ${REGION_SECONDARY}"
