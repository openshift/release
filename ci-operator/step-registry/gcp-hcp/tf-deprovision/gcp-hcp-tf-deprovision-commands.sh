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

# Read terraform version — use awk to avoid grep pipefail on missing entry
if ! TERRAFORM_VERSION="$(awk '$1 == "terraform" { print $2; exit }' "${REPO_ROOT}/.tool-versions")" \
  || [[ -z "${TERRAFORM_VERSION}" ]]; then
  log "ERROR: Failed to read terraform version from .tool-versions"
  log "Auto-destroy will clean up resources in 24h"
  exit 0  # Don't fail job
fi

log "Installing Terraform ${TERRAFORM_VERSION}..."
if ! curl -fsSL --connect-timeout 15 --max-time 300 "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip; then
  log "ERROR: Failed to download Terraform ${TERRAFORM_VERSION}"
  log "Auto-destroy will clean up resources in 24h"
  exit 0  # Don't fail job
fi
if ! python3 -c "import zipfile; zipfile.ZipFile('/tmp/terraform.zip').extractall('/tmp')"; then
  log "ERROR: Failed to extract Terraform"
  log "Auto-destroy will clean up resources in 24h"
  exit 0  # Don't fail job
fi
if ! chmod +x /tmp/terraform; then
  log "ERROR: Failed to make Terraform executable"
  log "Auto-destroy will clean up resources in 24h"
  exit 0  # Don't fail job
fi
export PATH="/tmp:${PATH}"

# We need the same terraform config that was used in provision
# Re-render using the same run-id
cd "${REPO_ROOT}"  # gcp-hcp-infra repo root (from: src)

# Patch render script to use cp instead of rsync if rsync is missing.
# TODO: Remove once gcp-hcp-infra-base image includes rsync (GITOPS-10466 blocks rebuild).
if ! command -v rsync >/dev/null 2>&1; then
  log "rsync not available, patching e2e-render.sh to use cp..."
  sed -i 's/rsync -a/cp -a/g' scripts/e2e-render.sh
  sed -i "s/--exclude='\.terraform' //g" scripts/e2e-render.sh
fi

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
