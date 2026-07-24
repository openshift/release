#!/usr/bin/env bash

set -euo pipefail

if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "ERROR: ${SHARED_DIR}/wif-cred.json not found — hypershift-gcp-wif-auth step must run first"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/ci-folder-id" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/ci-folder-id not found in cluster profile"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/billing-account-id" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/billing-account-id not found in cluster profile"
  exit 1
fi

export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"

cd terraform/config/e2e-smoke

terraform init -input=false
terraform plan -input=false

echo "Terraform plan completed successfully"
