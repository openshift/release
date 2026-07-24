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

CI_FOLDER_ID="$(<"${CLUSTER_PROFILE_DIR}/ci-folder-id")"

CRED_CONFIG="${SHARED_DIR}/wif-cred.json"
SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"

AUDIENCE=$(jq -r '.audience' "${CRED_CONFIG}")
SA_IMPERSONATION_URL=$(jq -r '.service_account_impersonation_url' "${CRED_CONFIG}")
SA_EMAIL=$(echo "${SA_IMPERSONATION_URL}" | grep -oP 'serviceAccounts/\K[^:]+')

echo "Step 1/3: Exchanging SA token for GCP federated token..."
STS_RESPONSE=$(curl -sf -X POST "https://sts.googleapis.com/v1/token" \
  -H "Content-Type: application/json" \
  -d "{
    \"grant_type\": \"urn:ietf:params:oauth:grant-type:token-exchange\",
    \"audience\": \"${AUDIENCE}\",
    \"scope\": \"https://www.googleapis.com/auth/cloud-platform\",
    \"requested_token_type\": \"urn:ietf:params:oauth:token-type:access_token\",
    \"subject_token_type\": \"urn:ietf:params:oauth:token-type:jwt\",
    \"subject_token\": \"$(cat ${SA_TOKEN_FILE})\"
  }") || { echo "ERROR: STS token exchange failed"; exit 1; }

FED_TOKEN=$(echo "${STS_RESPONSE}" | jq -r '.access_token')
echo "  OK"

echo "Step 2/3: Impersonating ${SA_EMAIL}..."
ACCESS_TOKEN_RESPONSE=$(curl -sf -X POST "${SA_IMPERSONATION_URL}" \
  -H "Authorization: Bearer ${FED_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"scope\": [\"https://www.googleapis.com/auth/cloud-platform\"]}") || { echo "ERROR: SA impersonation failed"; exit 1; }

ACCESS_TOKEN=$(echo "${ACCESS_TOKEN_RESPONSE}" | jq -r '.accessToken')
echo "  OK"

echo "Step 3/3: Listing projects in CI folder ${CI_FOLDER_ID}..."
PROJECTS_RESPONSE=$(curl -sf \
  "https://cloudresourcemanager.googleapis.com/v1/projects?filter=parent.id%3A${CI_FOLDER_ID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}") || { echo "ERROR: GCP API call failed"; exit 1; }

PROJECT_ID=$(echo "${PROJECTS_RESPONSE}" | jq -r '.projects[0].projectId // empty')
echo "  OK"

echo ""
echo "=== WIF Smoke Test Passed ==="
echo "  SA:      ${SA_EMAIL}"
echo "  Folder:  ${CI_FOLDER_ID}"
echo "  Project: ${PROJECT_ID}"
echo ""
echo "WIF authentication verified end-to-end"
