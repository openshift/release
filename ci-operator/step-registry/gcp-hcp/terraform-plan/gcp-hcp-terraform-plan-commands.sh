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

echo "Exchanging SA token for GCP federated token..."
STS_RESPONSE=$(curl -s -X POST "https://sts.googleapis.com/v1/token" \
  -H "Content-Type: application/json" \
  -d "{
    \"grant_type\": \"urn:ietf:params:oauth:grant-type:token-exchange\",
    \"audience\": \"${AUDIENCE}\",
    \"scope\": \"https://www.googleapis.com/auth/cloud-platform\",
    \"requested_token_type\": \"urn:ietf:params:oauth:token-type:access_token\",
    \"subject_token_type\": \"urn:ietf:params:oauth:token-type:jwt\",
    \"subject_token\": \"$(cat ${SA_TOKEN_FILE})\"
  }")

FED_TOKEN=$(echo "${STS_RESPONSE}" | jq -r '.access_token // empty')
if [[ -z "${FED_TOKEN}" ]]; then
  echo "ERROR: STS token exchange failed"
  echo "${STS_RESPONSE}" | jq . 2>/dev/null || echo "${STS_RESPONSE}"
  exit 1
fi
echo "STS token exchange succeeded"

echo "Impersonating ${SA_EMAIL}..."
ACCESS_TOKEN_RESPONSE=$(curl -s -X POST "${SA_IMPERSONATION_URL}" \
  -H "Authorization: Bearer ${FED_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"scope\": [\"https://www.googleapis.com/auth/cloud-platform\"]}")

ACCESS_TOKEN=$(echo "${ACCESS_TOKEN_RESPONSE}" | jq -r '.accessToken // empty')
if [[ -z "${ACCESS_TOKEN}" ]]; then
  echo "ERROR: SA impersonation failed"
  echo "${ACCESS_TOKEN_RESPONSE}" | jq . 2>/dev/null || echo "${ACCESS_TOKEN_RESPONSE}"
  exit 1
fi
echo "SA impersonation succeeded"

echo "Verifying GCP API access (listing projects in CI folder)..."
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "https://cloudresourcemanager.googleapis.com/v3/projects:search" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"parent:folders/${CI_FOLDER_ID}\"}")

HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tail -1)
RESPONSE_BODY=$(echo "${HTTP_RESPONSE}" | sed '$d')

if [[ "${HTTP_STATUS}" != "200" ]]; then
  echo "ERROR: GCP API call failed (HTTP ${HTTP_STATUS})"
  echo "${RESPONSE_BODY}" | jq . 2>/dev/null || echo "${RESPONSE_BODY}"
  exit 1
fi

echo ""
echo "=== WIF Smoke Test Passed ==="
echo "  SA:      ${SA_EMAIL}"
echo "  Folder:  ${CI_FOLDER_ID}"
echo "  HTTP:    ${HTTP_STATUS}"
echo ""
echo "WIF authentication verified end-to-end"
