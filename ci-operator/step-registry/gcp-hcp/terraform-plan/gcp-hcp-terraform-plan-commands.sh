#!/usr/bin/env bash
#
# WIF Authentication Smoke Test
#
# Temporary validation step that proves Workload Identity Federation works
# end-to-end from Prow build clusters. This will be replaced by actual
# terraform apply/plan steps once TF Cloud integration is implemented (GCP-919).
#
# The test performs three GCP API calls using only curl:
#   1. STS token exchange (K8s SA token → federated token)
#   2. SA impersonation (federated token → platform-ci SA access token)
#   3. Projects list (verifies the SA can access the CI folder)

set -euo pipefail

LOG="${ARTIFACT_DIR}/wif-smoke-test.log"

log() {
  echo "$@" | tee -a "${LOG}"
}

if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  log "ERROR: ${SHARED_DIR}/wif-cred.json not found — wif-auth step must run first"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/ci-folder-id" ]]; then
  log "ERROR: ${CLUSTER_PROFILE_DIR}/ci-folder-id not found in cluster profile"
  exit 1
fi

CI_FOLDER_ID="$(<"${CLUSTER_PROFILE_DIR}/ci-folder-id")"

CRED_CONFIG="${SHARED_DIR}/wif-cred.json"
SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"

AUDIENCE=$(jq -r '.audience' "${CRED_CONFIG}")
SA_IMPERSONATION_URL=$(jq -r '.service_account_impersonation_url' "${CRED_CONFIG}")
SA_EMAIL=$(echo "${SA_IMPERSONATION_URL}" | grep -oP 'serviceAccounts/\K[^:]+')

# Step 1: Exchange the pod's projected K8s SA token for a GCP federated token
# via the Security Token Service (STS). This proves the build cluster's OIDC
# issuer is trusted by our WIF pool.
log "Step 1/3: Exchanging SA token for GCP federated token..."
STS_RESPONSE=$(curl -sf -X POST "https://sts.googleapis.com/v1/token" \
  -H "Content-Type: application/json" \
  -d "{
    \"grant_type\": \"urn:ietf:params:oauth:grant-type:token-exchange\",
    \"audience\": \"${AUDIENCE}\",
    \"scope\": \"https://www.googleapis.com/auth/cloud-platform\",
    \"requested_token_type\": \"urn:ietf:params:oauth:token-type:access_token\",
    \"subject_token_type\": \"urn:ietf:params:oauth:token-type:jwt\",
    \"subject_token\": \"$(cat ${SA_TOKEN_FILE})\"
  }") || { log "ERROR: STS token exchange failed"; exit 1; }

FED_TOKEN=$(echo "${STS_RESPONSE}" | jq -r '.access_token')
log "  OK"

# Step 2: Use the federated token to impersonate the platform-ci SA.
# This proves the IAM binding (workloadIdentityUser) is correctly configured.
log "Step 2/3: Impersonating ${SA_EMAIL}..."
ACCESS_TOKEN_RESPONSE=$(curl -sf -X POST "${SA_IMPERSONATION_URL}" \
  -H "Authorization: Bearer ${FED_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"scope\": [\"https://www.googleapis.com/auth/cloud-platform\"]}") || { log "ERROR: SA impersonation failed"; exit 1; }

ACCESS_TOKEN=$(echo "${ACCESS_TOKEN_RESPONSE}" | jq -r '.accessToken')
log "  OK"

# Step 3: Make a real GCP API call to verify the access token works.
# Lists projects in the CI folder — the SA has this permission via
# roles/resourcemanager.projectCreator on the folder.
log "Step 3/3: Listing projects in CI folder ${CI_FOLDER_ID}..."
PROJECTS_RESPONSE=$(curl -sf \
  "https://cloudresourcemanager.googleapis.com/v1/projects?filter=parent.id%3A${CI_FOLDER_ID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}") || { log "ERROR: GCP API call failed"; exit 1; }

PROJECT_ID=$(echo "${PROJECTS_RESPONSE}" | jq -r '.projects[0].projectId // empty')
log "  OK"

log ""
log "=== WIF Smoke Test Passed ==="
log "  SA:      ${SA_EMAIL}"
log "  Folder:  ${CI_FOLDER_ID}"
log "  Project: ${PROJECT_ID}"
log ""
log "WIF authentication verified end-to-end"
