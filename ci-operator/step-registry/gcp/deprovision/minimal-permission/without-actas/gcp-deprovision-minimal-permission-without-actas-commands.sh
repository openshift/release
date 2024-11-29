#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

iam_account=$(jq -r .client_email ${SHARED_DIR}/gcp_min_permissions_without_actas.json)
key_id=$(jq -r .private_key_id ${SHARED_DIR}/gcp_min_permissions_without_actas.json)
gcloud iam service-accounts keys delete -q "${key_id}" --iam-account="${iam_account}" || exit 1
echo "$(date -u --rfc-3339=seconds) - Deleted the temporary key of the IAM service account, which hasn't the 'iam.serviceAccounts.actAs' permission, for GCP minimum permissions testing."
