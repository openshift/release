#!/usr/bin/env bash
set -euo pipefail

LOG="${ARTIFACT_DIR}/deprovision.log"
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') | $*" | tee -a "${LOG}"; }

# Try to read from SHARED_DIR, fall back to reconstructing from BUILD_ID
if [[ -f "${SHARED_DIR}/workspace-name" && -f "${SHARED_DIR}/run-id" ]]; then
  WORKSPACE_NAME="$(<${SHARED_DIR}/workspace-name)"
  RUN_ID="$(<${SHARED_DIR}/run-id)"
  log "Using workspace info from SHARED_DIR: ${WORKSPACE_NAME}"
else
  log "WARNING: Workspace info not in SHARED_DIR - reconstructing from BUILD_ID"
  
  # Reconstruct run-id using same hash function as provision
  RUN_ID="b$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-7)"
  WORKSPACE_NAME="platform-e2e-${RUN_ID}"
  
  log "Reconstructed workspace: ${WORKSPACE_NAME}"
fi

# Try to use WIF credentials from SHARED_DIR, fall back to reconstructing from profile
if [[ -f "${SHARED_DIR}/wif-cred.json" ]]; then
  log "Using WIF credentials from SHARED_DIR"
else
  log "WARNING: WIF credentials not in SHARED_DIR - reconstructing from cluster profile"
  
  # Reconstruct WIF credentials (pattern from hypershift-gcp-wif-auth)
  SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
  SA_TOKEN_PAYLOAD=$(cut -d. -f2 < "${SA_TOKEN_FILE}")
  MOD=$(( ${#SA_TOKEN_PAYLOAD} % 4 ))
  if [[ $MOD -eq 2 ]]; then SA_TOKEN_PAYLOAD="${SA_TOKEN_PAYLOAD}=="; 
  elif [[ $MOD -eq 3 ]]; then SA_TOKEN_PAYLOAD="${SA_TOKEN_PAYLOAD}="; fi
  OIDC_ISSUER=$(echo "${SA_TOKEN_PAYLOAD}" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.iss')
  
  WIF_CONFIG="${CLUSTER_PROFILE_DIR}/wif-config.json"
  if [[ ! -f "${WIF_CONFIG}" ]]; then
    log "ERROR: Cannot reconstruct WIF credentials - ${WIF_CONFIG} not found"
    exit 0  # Don't fail job - auto-destroy will clean up
  fi
  
  PROJECT_NUMBER=$(jq -r '.project_number // empty' "${WIF_CONFIG}")
  POOL_ID=$(jq -r '.pool_id // empty' "${WIF_CONFIG}")
  SERVICE_ACCOUNT=$(jq -r '.service_account // empty' "${WIF_CONFIG}")
  PROVIDER_ID=$(jq -r --arg iss "${OIDC_ISSUER}" '.issuer_map[$iss] // empty' "${WIF_CONFIG}")
  
  if [[ -z "${PROJECT_NUMBER}" || -z "${POOL_ID}" || -z "${SERVICE_ACCOUNT}" || -z "${PROVIDER_ID}" ]]; then
    log "ERROR: Failed to reconstruct WIF credentials from cluster profile"
    exit 0  # Don't fail job
  fi
  
  # Write reconstructed credentials
  cat > "${SHARED_DIR}/wif-cred.json" <<EOF
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "file": "${SA_TOKEN_FILE}",
    "format": {"type": "text"}
  },
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SERVICE_ACCOUNT}:generateAccessToken"
}
EOF
  
  log "WIF credentials reconstructed successfully"
fi

log "Deprovisioning infrastructure for workspace: ${WORKSPACE_NAME}"

# --- Authenticate to GCP ---

log "Authenticating to GCP via WIF..."
gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet
gcloud config set project gcp-hcp-platform-ci

# We need the same terraform config that was used in provision
# Re-render using the same run-id
cd "${SRC_DIR}"  # gcp-hcp-infra repo

REGION="${GCP_REGION:-us-central1}"

log "Re-rendering template for run ID: ${RUN_ID}"
RENDERED_DIR="$(./scripts/e2e-render.sh "${RUN_ID}" "${REGION}")"

cd "${RENDERED_DIR}"

# Configure TFC authentication via .terraformrc (avoids token in env vars)
cat > "$HOME/.terraformrc" <<TFRC
credentials "app.terraform.io" {
  token = "$(cat /etc/terraform-cloud/token)"
}
TFRC

export TF_INPUT=false
export TF_IN_AUTOMATION=true

log "Initializing terraform..."
if ! terraform init -no-color 2>&1 | tee -a "${LOG}"; then
  log "ERROR: terraform init failed"
  log "Auto-destroy will clean up resources in 24h"
  exit 0  # Don't fail job
fi

TFC_ORG="hp-platform-engineering"
log "Running terraform destroy..."
log "TFC workspace: https://app.terraform.io/app/${TFC_ORG}/workspaces/${WORKSPACE_NAME}"

if ! terraform destroy -auto-approve -no-color 2>&1 | tee -a "${LOG}"; then
  log "WARNING: terraform destroy failed"
  log "Resources will be cleaned up by auto-destroy after 24h of inactivity"
  log "Check TFC workspace for details: https://app.terraform.io/app/${TFC_ORG}/workspaces/${WORKSPACE_NAME}"
  exit 0  # Don't fail job - this is cleanup only
fi

log ""
log "=== Deprovision Complete ==="
log "  Workspace:     ${WORKSPACE_NAME}"
log "  Run ID:        ${RUN_ID}"
log ""
log "Infrastructure destroyed successfully"
log "TFC workspace preserved for debug history"
