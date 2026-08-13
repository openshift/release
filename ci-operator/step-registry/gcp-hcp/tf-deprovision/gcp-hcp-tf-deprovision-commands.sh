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

# Validate TFC token mount exists
if [[ ! -f "/etc/terraform-cloud/token" ]]; then
  log "ERROR: /etc/terraform-cloud/token not found"
  log "Auto-destroy will clean up resources in 24h"
  exit 0  # Don't fail job
fi

log "Deprovisioning infrastructure for workspace: ${WORKSPACE_NAME}"

# NOTE: gcloud is NOT needed here. TFC remote execution handles GCP auth
# via the WIF variable set on the TFC workspace — no local gcloud required.

# --- Install Terraform ---

# The 'src' image already contains the gcp-hcp-infra repo at the working directory.
REPO_ROOT="$(pwd)"

# Read terraform version from .tool-versions to ensure consistency with local dev
TERRAFORM_VERSION="$(grep '^terraform' "${REPO_ROOT}/.tool-versions" | awk '{print $2}')"

if [[ -z "${TERRAFORM_VERSION}" ]]; then
  log "ERROR: Failed to read terraform version from .tool-versions"
  exit 0  # Don't fail job
fi

log "Installing Terraform ${TERRAFORM_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
python3 -c "import zipfile; zipfile.ZipFile('/tmp/terraform.zip').extractall('/tmp')"
chmod +x /tmp/terraform
export PATH="/tmp:${PATH}"

# We need the same terraform config that was used in provision
# Re-render using the same run-id
cd "${REPO_ROOT}"  # gcp-hcp-infra repo root (from: src)

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
