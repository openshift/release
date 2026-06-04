#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  trap - EXIT ERR INT TERM
  set +o errexit

  echo "[INFO] **** Starting emergency cleanup for failed cluster creation..."

  if [[ -n "${DYNAMIC_BUCKET_NAME:-}" ]]; then
    export PULUMI_K8S_DELETE_UNREACHABLE=true
    echo "[INFO] **** Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

    echo "[INFO] **** Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."

    if mapt aws openshift-snc destroy \
      --project-name "${CORRELATE_MAPT}" \
      --backed-url "s3://${DYNAMIC_BUCKET_NAME}" 2>&1; then
      echo "[SUCCESS] !!!! Successfully destroyed MAPT infrastructure during cleanup"
    else
      echo "[WARN] WARN MAPT destroy may have failed, but continuing with bucket cleanup"
    fi

    echo "[INFO] **** Emergency cleanup: Deleting S3 bucket: ${DYNAMIC_BUCKET_NAME}..."

    local _km="" _vm="" _page _nk
    while true; do
      if [[ -n "${_km}" ]]; then
        _page=$(aws s3api list-object-versions \
          --bucket "${DYNAMIC_BUCKET_NAME}" \
          --key-marker "${_km}" \
          --version-id-marker "${_vm}" \
          --output json 2>/dev/null || echo '{}')
      else
        _page=$(aws s3api list-object-versions \
          --bucket "${DYNAMIC_BUCKET_NAME}" \
          --output json 2>/dev/null || echo '{}')
      fi

      echo "${_page}" | jq -r '(.Versions[]?, .DeleteMarkers[]?) | @base64' | \
      while IFS= read -r row; do
        key="$(echo "${row}" | base64 -d | jq -r '.Key')"
        version_id="$(echo "${row}" | base64 -d | jq -r '.VersionId')"
        aws s3api delete-object \
          --bucket "${DYNAMIC_BUCKET_NAME}" \
          --key "${key}" \
          --version-id "${version_id}" >/dev/null 2>&1 || true
      done

      _nk=$(echo "${_page}" | jq -r '.NextKeyMarker // empty')
      if [[ -z "${_nk}" ]]; then
        break
      fi
      _km="${_nk}"
      _vm=$(echo "${_page}" | jq -r '.NextVersionIdMarker // empty')
    done

    aws s3 rm "s3://${DYNAMIC_BUCKET_NAME}" --recursive 2>/dev/null || true
    aws s3 rb "s3://${DYNAMIC_BUCKET_NAME}" 2>/dev/null || echo "[WARN] WARN Bucket deletion failed or bucket already deleted"
    rm -f "${SHARED_DIR}/mapt-s3-bucket-name" || true

    echo "[INFO] !!!! Emergency S3 bucket cleanup attempted"
  fi

  set -o errexit
  exit 1
}

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

echo "[INFO] AUTH Loading AWS credentials from vault..."
aws_validation
echo "[SUCCESS] !!!! AWS credentials loaded successfully"

if [ ! -f /tmp/secrets/pull-secret ]; then
  echo "Error: Pull secret file not found"
  exit 1
fi

echo "[INFO] TAG Setting CORRELATE_MAPT..."
CORRELATE_MAPT="ossm-istio-snc-${BUILD_ID:-unknown}"
export CORRELATE_MAPT

echo "[INFO] BUCKET Creating dynamic S3 bucket for MAPT state storage..."
DYNAMIC_BUCKET_NAME="ossm-mapt-${CORRELATE_MAPT}-$(date +%s)"
export DYNAMIC_BUCKET_NAME

if [[ "${AWS_REGION}" == "us-east-1" ]]; then
  aws s3 mb "s3://${DYNAMIC_BUCKET_NAME}"
else
  aws s3 mb "s3://${DYNAMIC_BUCKET_NAME}" --region "${AWS_REGION}"
fi

aws s3api put-bucket-versioning \
  --bucket "${DYNAMIC_BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-tagging \
  --bucket "${DYNAMIC_BUCKET_NAME}" \
  --tagging 'TagSet=[
    {Key=app-code,Value=ossm-mapt},
    {Key=mapt-job,Value='${CORRELATE_MAPT}'},
    {Key=build-id,Value='${BUILD_ID:-unknown}'},
    {Key=auto-cleanup,Value=true}
  ]'

echo "[SUCCESS] !!!! S3 bucket created: ${DYNAMIC_BUCKET_NAME}"

echo "${DYNAMIC_BUCKET_NAME}" > "${SHARED_DIR}/mapt-s3-bucket-name"
echo "[INFO] SAVE Saved bucket name to ${SHARED_DIR}/mapt-s3-bucket-name for cleanup"

echo "[INFO] RESOURCE ======================================================"
echo "[INFO] RESOURCE AWS resource identifiers (for manual cleanup if needed)"
echo "[INFO] RESOURCE   MAPT project / EC2 instance name : ${CORRELATE_MAPT}"
echo "[INFO] RESOURCE   S3 state bucket                  : ${DYNAMIC_BUCKET_NAME}"
echo "[INFO] RESOURCE   AWS region                       : ${AWS_REGION}"
echo "[INFO] RESOURCE ======================================================"

# Trap EXIT/ERR/INT/TERM to ensure MAPT infrastructure is destroyed on failure or cancellation
trap cleanup EXIT ERR INT TERM

OCP_VERSION=${OCP_VERSION:-"4.21.14"}
CPU=${CPU:-"8"}
MEMORY=${MEMORY:-"32"}
SPOT=${SPOT:-"true"}
SPOT_INCREASE_RATE=${SPOT_INCREASE_RATE:-"60"}
MAPT_TAGS=${MAPT_TAGS:-"ci=true,repo=openshift-servicemesh"}

echo "[INFO] START Creating OSSM Istio MAPT OpenShift SNC infrastructure for ${CORRELATE_MAPT}..."
echo "[INFO] LOC Using S3 state backend: s3://${DYNAMIC_BUCKET_NAME}"
echo "[INFO] INFO SNC Configuration: OpenShift ${OCP_VERSION}, ${CPU} CPU, ${MEMORY}GB RAM, spot=${SPOT}"

MAPT_SPOT_ARGS=()
if [[ "${SPOT}" == "true" ]]; then
  MAPT_SPOT_ARGS=(--spot --spot-increase-rate "${SPOT_INCREASE_RATE}")
fi

mapt aws openshift-snc create \
  --backed-url "s3://${DYNAMIC_BUCKET_NAME}" \
  --conn-details-output "${SHARED_DIR}" \
  --pull-secret-file /tmp/secrets/pull-secret \
  --project-name "${CORRELATE_MAPT}" \
  --tags "project=crc,${MAPT_TAGS}" \
  --version "${OCP_VERSION}" \
  --cpus "${CPU}" \
  --memory "${MEMORY}" \
  "${MAPT_SPOT_ARGS[@]}"

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "[ERROR] ERROR kubeconfig file not found at ${SHARED_DIR}/kubeconfig"
  echo "[ERROR] ERROR Failed to create MAPT OpenShift SNC cluster"
  exit 1
fi
echo "[SUCCESS] !!!! OSSM Istio MAPT OpenShift SNC cluster created successfully"

echo "[INFO] SAVE Saving kubeconfig location for test step..."
echo "[INFO] FILE Kubeconfig available at: ${SHARED_DIR}/kubeconfig"

# Clear trap on successful completion so cleanup does not run on normal exit
trap - EXIT ERR INT TERM
echo "[SUCCESS] !!!! MAPT OpenShift SNC cluster ready for testing"
echo "[INFO] INFO Namespace and pod security setup will be handled by test step"