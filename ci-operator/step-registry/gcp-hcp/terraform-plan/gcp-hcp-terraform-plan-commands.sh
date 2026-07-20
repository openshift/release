#!/usr/bin/env bash

set -euo pipefail

if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "ERROR: ${SHARED_DIR}/wif-cred.json not found — hypershift-gcp-wif-auth step must run first"
  exit 1
fi

gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json"

CI_FOLDER_ID="$(<"${CLUSTER_PROFILE_DIR}/ci-folder-id")"
BILLING_ACCOUNT_ID="$(<"${CLUSTER_PROFILE_DIR}/billing-account-id")"

echo "CI Folder ID: ${CI_FOLDER_ID}"
echo "Authenticated as: $(gcloud auth list --filter=status:ACTIVE --format='value(account)')"

cd terraform/config/region/integration/e2e/us-central1

terraform init
terraform plan -input=false

echo "Terraform plan completed successfully"
