#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export CLOUDSDK_PYTHON=python3

GOOGLE_PROJECT_ID="$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email "${GCP_SHARED_CREDENTIALS_FILE}")
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -Fxq "${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

echo "$(date -u --rfc-3339=seconds) - Retrieving cluster infrastructure ID..."
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
if [[ -z "${INFRA_ID}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to retrieve infrastructure ID from cluster, abort."
  exit 1
fi
echo "$(date -u --rfc-3339=seconds) - Infrastructure ID: ${INFRA_ID}"

KMS_KEY_RING="$(< "${SHARED_DIR}/gcp_kms_key_ring")"
KMS_KEY_NAME="$(< "${SHARED_DIR}/gcp_kms_key_name")"
KMS_KEY_LOCATION="$(< "${SHARED_DIR}/gcp_kms_key_location")"

EXPECTED_KMS_KEY="projects/${GOOGLE_PROJECT_ID}/locations/${KMS_KEY_LOCATION}/keyRings/${KMS_KEY_RING}/cryptoKeys/${KMS_KEY_NAME}"
echo "$(date -u --rfc-3339=seconds) - Expected KMS key: ${EXPECTED_KMS_KEY}"

VALIDATION_FAILED=0

verify_bucket_encryption() {
  local bucket_name=$1
  local bucket_purpose=$2

  echo "$(date -u --rfc-3339=seconds) - Verifying ${bucket_purpose} bucket: ${bucket_name}"

  if ! gsutil ls "gs://${bucket_name}" &>/dev/null; then
    echo "$(date -u --rfc-3339=seconds) - ${bucket_purpose} bucket '${bucket_name}' does not exist (may have been deleted)"
    return 0
  fi

  echo "$(date -u --rfc-3339=seconds) - Bucket exists, checking encryption configuration..."

  ENCRYPTION_CONFIG=$(gcloud storage buckets describe "gs://${bucket_name}" \
    --format="json(encryption)" 2>&1) || {
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to describe bucket ${bucket_name}"
    echo "${ENCRYPTION_CONFIG}"
    return 1
  }

  if echo "${ENCRYPTION_CONFIG}" | jq -e '.encryption.defaultKmsKeyName' &>/dev/null; then
    ACTUAL_KMS_KEY=$(echo "${ENCRYPTION_CONFIG}" | jq -r '.encryption.defaultKmsKeyName')
    echo "$(date -u --rfc-3339=seconds) - Actual KMS key: ${ACTUAL_KMS_KEY}"

    if [[ "${ACTUAL_KMS_KEY}" == "${EXPECTED_KMS_KEY}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - ${bucket_purpose} bucket is encrypted with correct KMS key"
      return 0
    else
      echo "$(date -u --rfc-3339=seconds) - ERROR: ${bucket_purpose} bucket KMS key mismatch"
      echo "$(date -u --rfc-3339=seconds) -   Expected: ${EXPECTED_KMS_KEY}"
      echo "$(date -u --rfc-3339=seconds) -   Actual:   ${ACTUAL_KMS_KEY}"
      return 1
    fi
  else
    echo "$(date -u --rfc-3339=seconds) - ERROR: ${bucket_purpose} bucket has no KMS encryption configured"
    echo "${ENCRYPTION_CONFIG}"
    return 1
  fi
}

REGISTRY_BUCKET="${INFRA_ID}-image-registry"
if verify_bucket_encryption "${REGISTRY_BUCKET}" "Image registry"; then
  echo "$(date -u --rfc-3339=seconds) - Image registry bucket validation: PASSED"
else
  echo "$(date -u --rfc-3339=seconds) - ERROR: Image registry bucket validation FAILED"
  VALIDATION_FAILED=1
fi

echo "$(date -u --rfc-3339=seconds) - Verifying ImageRegistry CR configuration..."
REGISTRY_CONFIG=$(oc get config.imageregistry.operator.openshift.io/cluster -o json 2>&1) || {
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to get ImageRegistry CR"
  echo "${REGISTRY_CONFIG}"
  VALIDATION_FAILED=1
  REGISTRY_CONFIG=""
}

if [[ -n "${REGISTRY_CONFIG}" ]] && echo "${REGISTRY_CONFIG}" | jq -e '.spec.storage.gcs.keyID' &>/dev/null; then
  REGISTRY_KEY_ID=$(echo "${REGISTRY_CONFIG}" | jq -r '.spec.storage.gcs.keyID')
  echo "$(date -u --rfc-3339=seconds) - ImageRegistry CR keyID: ${REGISTRY_KEY_ID}"

  if [[ "${REGISTRY_KEY_ID}" == "${EXPECTED_KMS_KEY}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ImageRegistry CR has correct KMS key configured"
  else
    echo "$(date -u --rfc-3339=seconds) - ERROR: ImageRegistry CR KMS key mismatch"
    echo "$(date -u --rfc-3339=seconds) -   Expected: ${EXPECTED_KMS_KEY}"
    echo "$(date -u --rfc-3339=seconds) -   Actual:   ${REGISTRY_KEY_ID}"
    VALIDATION_FAILED=1
  fi
else
  echo "$(date -u --rfc-3339=seconds) - ERROR: ImageRegistry CR does not have keyID configured"
  VALIDATION_FAILED=1
fi

if [[ ${VALIDATION_FAILED} -eq 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - KMS bucket encryption validation: PASSED"
  exit 0
else
  echo "$(date -u --rfc-3339=seconds) - KMS bucket encryption validation: FAILED"
  exit 1
fi
