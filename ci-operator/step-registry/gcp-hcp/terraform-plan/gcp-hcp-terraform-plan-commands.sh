#!/usr/bin/env bash

set -euo pipefail

if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "ERROR: ${SHARED_DIR}/wif-cred.json not found — hypershift-gcp-wif-auth step must run first"
  exit 1
fi

CI_FOLDER_ID="$(<"${CLUSTER_PROFILE_DIR}/ci-folder-id")"
BILLING_ACCOUNT_ID="$(<"${CLUSTER_PROFILE_DIR}/billing-account-id")"

if [[ -z "${CI_FOLDER_ID}" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/ci-folder-id not found or empty"
  exit 1
fi

if [[ -z "${BILLING_ACCOUNT_ID}" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/billing-account-id not found or empty"
  exit 1
fi

export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"

cd terraform/config/region/integration/e2e/us-central1

terraform init
terraform plan -input=false

echo "Terraform plan completed successfully"
