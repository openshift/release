#!/usr/bin/env bash

set -euo pipefail

# Extract the OIDC issuer from the pod's projected service account token.
# The token is a JWT; the payload (2nd segment) is base64url-encoded JSON.
SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_TOKEN_PAYLOAD=$(cut -d. -f2 < "${SA_TOKEN_FILE}")
MOD=$(( ${#SA_TOKEN_PAYLOAD} % 4 ))
if [[ $MOD -eq 2 ]]; then SA_TOKEN_PAYLOAD="${SA_TOKEN_PAYLOAD}=="; elif [[ $MOD -eq 3 ]]; then SA_TOKEN_PAYLOAD="${SA_TOKEN_PAYLOAD}="; fi
OIDC_ISSUER=$(echo "${SA_TOKEN_PAYLOAD}" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.iss')

WIF_CONFIG="${CLUSTER_PROFILE_DIR}/wif-config.json"

# Read all WIF infrastructure values from the consolidated config file.
PROJECT_NUMBER=$(jq -r '.project_number // empty' "${WIF_CONFIG}")
POOL_ID=$(jq -r '.pool_id // empty' "${WIF_CONFIG}")
SERVICE_ACCOUNT=$(jq -r '.service_account // empty' "${WIF_CONFIG}")
PROVIDER_ID=$(jq -r --arg iss "${OIDC_ISSUER}" '.issuer_map[$iss] // empty' "${WIF_CONFIG}")

# Validate all required values are present.
if [[ -z "${PROJECT_NUMBER}" ]]; then
  echo "ERROR: .project_number is missing or empty in ${WIF_CONFIG}"
  exit 1
fi
if [[ -z "${POOL_ID}" ]]; then
  echo "ERROR: .pool_id is missing or empty in ${WIF_CONFIG}"
  exit 1
fi
if [[ -z "${SERVICE_ACCOUNT}" ]]; then
  echo "ERROR: .service_account is missing or empty in ${WIF_CONFIG}"
  exit 1
fi
if [[ -z "${PROVIDER_ID}" ]]; then
  echo "ERROR: OIDC issuer '${OIDC_ISSUER}' not found in .issuer_map of ${WIF_CONFIG}"
  echo "This build cluster may not have a WIF provider configured."
  exit 1
fi

# Write the WIF credential config to SHARED_DIR so all subsequent steps can authenticate.
# credential_source.file points to the token path (not its content), so gcloud re-reads
# a fresh token on each API call — no expiry issue across a long job.
cat > "${SHARED_DIR}/wif-cred.json" <<EOF
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "file": "${SA_TOKEN_FILE}",
    "format": {
      "type": "text"
    }
  },
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SERVICE_ACCOUNT}:generateAccessToken"
}
EOF

echo "WIF credential config written successfully"

# Smoke-test: validate WIF is working before any downstream step runs,
# using the same auth path as all downstream steps
if ! gcloud auth login --cred-file "${SHARED_DIR}/wif-cred.json"; then
  echo "ERROR: WIF login failed — verify wif-config.json in the cluster profile"
  echo "  project_number, pool_id, service_account, and issuer_map must all be correct"
  echo "  OIDC issuer detected: ${OIDC_ISSUER}"
  echo "  WIF provider mapped: ${PROVIDER_ID}"
  exit 1
fi
if ! gcloud auth print-access-token > /dev/null; then
  echo "ERROR: WIF token exchange failed — verify wif-config.json in the cluster profile"
  echo "  project_number, pool_id, service_account, and issuer_map must all be correct"
  echo "  OIDC issuer detected: ${OIDC_ISSUER}"
  echo "  WIF provider mapped: ${PROVIDER_ID}"
  exit 1
fi
echo "WIF authentication verified successfully"
