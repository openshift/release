#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

aws_validation() {
  echo "========== AWS Validation =========="
  echo "Validating AWS credentials..."
  CRED_FILE=""
  if [ -f "/tmp/secrets/.awscred" ]; then
    CRED_FILE="/tmp/secrets/.awscred"
  elif [ -f "/tmp/secrets/config" ]; then
    CRED_FILE="/tmp/secrets/config"
  else
    echo "Error: AWS credentials file not found (looked for .awscred and config)"
    exit 1
  fi

  echo "AWS credentials file located"

  export AWS_SHARED_CREDENTIALS_FILE="${CRED_FILE}"
  AWS_REGION=${AWS_REGION:-"us-east-1"}
  export AWS_REGION
}

# Deletes all object versions and delete markers (paginated), removes remaining
# objects, then removes the bucket. Returns the exit code of aws s3 rb.
purge_and_delete_bucket() {
  local bucket="${1}"
  local rb_rc=0

  echo "[INFO] **** Removing all object versions and delete markers from S3 bucket: ${bucket}..."
  # Loop until no versioned objects remain (each pass deletes one page of up to 1000)
  while true; do
    local _versions _dmarkers
    _versions=$(aws s3api list-object-versions \
      --bucket "${bucket}" \
      --output text \
      --query 'Versions[*].[Key,VersionId]' 2>/dev/null || true)
    _dmarkers=$(aws s3api list-object-versions \
      --bucket "${bucket}" \
      --output text \
      --query 'DeleteMarkers[*].[Key,VersionId]' 2>/dev/null || true)

    [[ -z "${_versions}" && -z "${_dmarkers}" ]] && break

    printf '%s\n%s\n' "${_versions}" "${_dmarkers}" | \
    while IFS=$'\t' read -r key version_id; do
      [[ -z "${key}" || -z "${version_id}" ]] && continue
      aws s3api delete-object \
        --bucket "${bucket}" \
        --key "${key}" \
        --version-id "${version_id}" >/dev/null 2>&1 || true
    done
  done

  echo "[INFO] **** Removing any remaining objects from S3 bucket: ${bucket}..."
  aws s3 rm "s3://${bucket}" --recursive 2>/dev/null || true

  echo "[INFO] **** Removing S3 bucket: ${bucket}..."
  aws s3 rb "s3://${bucket}" 2>/dev/null || rb_rc=$?
  return "${rb_rc}"
}

echo "[INFO] AUTH Loading AWS credentials from vault..."
aws_validation
echo "[SUCCESS] !!!! AWS credentials loaded successfully"

echo "[INFO] READ Reading shared artifacts from create step..."
echo "[INFO] SHARED_DIR contents: $(ls "${SHARED_DIR}" 2>/dev/null | tr '\n' ' ')"

if [[ ! -f "${SHARED_DIR}/mapt-s3-bucket-name" ]]; then
  echo "[WARN] WARN Bucket name file not found at ${SHARED_DIR}/mapt-s3-bucket-name"
  echo "[WARN] WARN Create step likely did not complete — nothing to clean up"
  exit 0
fi

DYNAMIC_BUCKET_NAME=$(cat "${SHARED_DIR}/mapt-s3-bucket-name")
export DYNAMIC_BUCKET_NAME

if [[ -f "${SHARED_DIR}/mapt-correlate-id" ]]; then
  CORRELATE_MAPT=$(cat "${SHARED_DIR}/mapt-correlate-id")
  echo "[INFO] TAG Loaded CORRELATE_MAPT from shared dir: ${CORRELATE_MAPT}"
else
  CORRELATE_MAPT="ossm-istio-snc-${BUILD_ID:-unknown}"
  echo "[WARN] WARN mapt-correlate-id not found; falling back to BUILD_ID: ${CORRELATE_MAPT}"
fi

echo "[INFO] RESOURCE ======================================================"
echo "[INFO] RESOURCE AWS resources targeted for cleanup"
echo "[INFO] RESOURCE   MAPT project / EC2 instance name : ${CORRELATE_MAPT}"
echo "[INFO] RESOURCE   S3 state bucket                  : ${DYNAMIC_BUCKET_NAME}"
echo "[INFO] RESOURCE   AWS region                       : ${AWS_REGION}"
echo "[INFO] RESOURCE ======================================================"

export PULUMI_K8S_DELETE_UNREACHABLE=true
echo "[INFO] **** Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "[INFO] **** Destroying OSSM Istio MAPT SNC infrastructure for ${CORRELATE_MAPT}..."
echo "[INFO] LOC Using S3 state backend: s3://${DYNAMIC_BUCKET_NAME}"

echo "[INFO] TIME Starting MAPT SNC destroy..."
if mapt aws openshift-snc destroy \
  --project-name "${CORRELATE_MAPT}" \
  --backed-url "s3://${DYNAMIC_BUCKET_NAME}"; then
  echo "[SUCCESS] !!!! Successfully destroyed OSSM Istio MAPT SNC: ${CORRELATE_MAPT}"

  if purge_and_delete_bucket "${DYNAMIC_BUCKET_NAME}"; then
    echo "[SUCCESS] !!!! Successfully deleted S3 bucket: ${DYNAMIC_BUCKET_NAME}"
  else
    echo "[WARN] WARN Failed to delete S3 bucket: ${DYNAMIC_BUCKET_NAME}"
    exit 1
  fi

  rm -f "${SHARED_DIR}/mapt-s3-bucket-name" "${SHARED_DIR}/mapt-correlate-id" || true

  echo "[SUCCESS] !!!! OSSM Istio MAPT SNC cleanup completed successfully"
else
  echo "[ERROR] ERROR MAPT SNC destroy failed"
  echo "[WARN] WARN Attempting best-effort S3 bucket cleanup despite destroy failure..."
  if purge_and_delete_bucket "${DYNAMIC_BUCKET_NAME}"; then
    echo "[INFO] **** Best-effort bucket cleanup succeeded: ${DYNAMIC_BUCKET_NAME}"
  else
    echo "[WARN] WARN Best-effort bucket cleanup failed; bucket ${DYNAMIC_BUCKET_NAME} may need manual cleanup"
  fi
  exit 1
fi
