#!/usr/bin/env bash
set -euo pipefail

LOG="${ARTIFACT_DIR}/provision.log"
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') | $*" | tee -a "${LOG}"; }

# Validate required tools are available
# NOTE: gcloud is NOT needed here. TFC remote execution handles GCP auth
# via the WIF variable set on the TFC workspace — no local gcloud required.
for tool in jq curl sha256sum; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log "ERROR: Required tool '${tool}' not found in image"
    log "The gcp-hcp-infra-base image should include all required utilities"
    exit 1
  fi
done

log "All required tools available"

# Validate TFC token mount exists
if [[ ! -f "/etc/terraform-cloud/token" ]]; then
  log "ERROR: /etc/terraform-cloud/token not found"
  log "The tfcloud-ci-secret vault mount must be configured"
  exit 1
fi

# Retry wrapper for TFC API calls with exponential backoff
tfc_api_call() {
  local max_retries=3
  local attempt=1
  
  while (( attempt <= max_retries )); do
    if output=$(curl -sf "$@" 2>&1); then
      echo "${output}"
      return 0
    fi
    
    if (( attempt < max_retries )); then
      local wait_time=$((attempt * 5))
      log "API call failed (attempt ${attempt}/${max_retries}), retrying in ${wait_time}s..." >&2
      sleep ${wait_time}
    fi
    
    ((attempt++))
  done
  
  log "ERROR: API call failed after ${max_retries} attempts" >&2
  return 1
}

# --- Install Terraform ---

# The 'src' image already contains the gcp-hcp-infra repo at the working directory.
# Read terraform version from .tool-versions to ensure consistency with local dev.
REPO_ROOT="$(pwd)"
TERRAFORM_VERSION="$(awk '$1 == "terraform" { print $2; exit }' "${REPO_ROOT}/.tool-versions")"

if [[ -z "${TERRAFORM_VERSION}" ]]; then
  log "ERROR: Failed to read terraform version from .tool-versions"
  exit 1
fi

if [[ ! "${TERRAFORM_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?$ ]]; then
  log "ERROR: Invalid terraform version format: ${TERRAFORM_VERSION}"
  exit 1
fi

log "Installing Terraform ${TERRAFORM_VERSION}..."
curl -fsSL --connect-timeout 15 --max-time 300 "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
# Use python3 (available in UBI9 image) to extract zip since unzip is not installed
python3 -c "import zipfile; zipfile.ZipFile('/tmp/terraform.zip').extractall('/tmp')"
chmod +x /tmp/terraform
export PATH="/tmp:${PATH}"

terraform version

# --- Generate Run ID ---

# Transform BUILD_ID (16-19 digit number) to valid run-id format
# Format: 'b' + first 7 hex chars of SHA-256(BUILD_ID) = 8 chars total
# Example: BUILD_ID=1770620651384959 → run_id=b7a3f2e1
# Use sha256sum (universally available in UBI9 base image)
RUN_ID="b$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-7)"

log "Generated run ID: ${RUN_ID} (from BUILD_ID: ${BUILD_ID})"

# Validate run-id format (should always pass with hash-based approach)
if [[ ! "${RUN_ID}" =~ ^[a-z][a-z0-9]{2,15}$ ]]; then
  log "ERROR: Generated run-id '${RUN_ID}' is invalid"
  log "This should never happen with hash-based generation"
  exit 1
fi

WORKSPACE_NAME="platform-e2e-${RUN_ID}"
REGION="${GCP_REGION:-us-central1}"

log "Configuration:"
log "  Run ID:      ${RUN_ID}"
log "  Workspace:   ${WORKSPACE_NAME}"
log "  Region:      ${REGION}"
log "  BUILD_ID:    ${BUILD_ID}"
log "  JOB_NAME:    ${JOB_NAME:-unknown}"

# --- Render Template ---

cd "${REPO_ROOT}"  # gcp-hcp-infra repo root (from: src)

log "Rendering e2e template..."
RENDERED_DIR="$(./scripts/e2e-render.sh "${RUN_ID}" "${REGION}")"

if [[ ! -d "${RENDERED_DIR}" ]]; then
  log "ERROR: Render script failed - directory not created"
  exit 1
fi

log "Template rendered to: ${RENDERED_DIR}"

# --- Configure Terraform ---

cd "${RENDERED_DIR}"

# Read TFC token once — used for both .terraformrc and API calls
TFC_TOKEN="$(cat /etc/terraform-cloud/token)"

# Configure TFC authentication via .terraformrc (avoids token in env vars)
(umask 077 && cat > "$HOME/.terraformrc" <<TFRC
credentials "app.terraform.io" {
  token = "${TFC_TOKEN}"
}
TFRC
)

# Disable terraform's interactive prompts
export TF_INPUT=false
export TF_IN_AUTOMATION=true

# --- Terraform Init ---

log "Initializing terraform (auto-creates TFC workspace)..."
if ! terraform init -no-color 2>&1 | tee -a "${LOG}"; then
  log "ERROR: terraform init failed"
  exit 1
fi

log "Workspace ${WORKSPACE_NAME} created successfully"

# --- Set Auto-Destroy ---

log "Configuring auto-destroy (24h safety net)..."

TFC_ORG="hp-platform-engineering"

# Get workspace ID from TFC API (with retry)
WORKSPACE_RESPONSE=$(tfc_api_call \
  "https://app.terraform.io/api/v2/organizations/${TFC_ORG}/workspaces/${WORKSPACE_NAME}" \
  -H "Authorization: Bearer ${TFC_TOKEN}" \
  -H "Content-Type: application/vnd.api+json")

WORKSPACE_ID=$(echo "${WORKSPACE_RESPONSE}" | jq -r '.data.id')

if [[ -z "${WORKSPACE_ID}" || "${WORKSPACE_ID}" == "null" ]]; then
  log "ERROR: Failed to retrieve workspace ID from TFC API"
  log "Workspace may not have been created properly"
  exit 1
fi

log "Workspace ID: ${WORKSPACE_ID}"

# Set auto-destroy to 24h (with retry)
if ! tfc_api_call -X PATCH \
  "https://app.terraform.io/api/v2/workspaces/${WORKSPACE_ID}" \
  -H "Authorization: Bearer ${TFC_TOKEN}" \
  -H "Content-Type: application/vnd.api+json" \
  -d "{\"data\":{\"type\":\"workspaces\",\"attributes\":{\"auto-destroy-activity-duration\":\"24h\"}}}" \
  > /dev/null; then
  log "WARNING: Failed to set auto-destroy after retries (non-fatal)"
  log "Resources may need manual cleanup if pipeline crashes"
else
  log "Auto-destroy configured successfully"
fi

# --- Terraform Apply (with retry) ---

log "Running terraform apply..."
log "TFC workspace: https://app.terraform.io/app/${TFC_ORG}/workspaces/${WORKSPACE_NAME}"

# Errors that retrying cannot fix — fail fast instead of wasting time
NON_TRANSIENT_ERRORS="quota.*exceeded|forbidden|invalid.*configuration|unauthorized"

MAX_APPLY_ATTEMPTS=5
apply_attempt=1
apply_wait=30

while (( apply_attempt <= MAX_APPLY_ATTEMPTS )); do
  log "APPLY ATTEMPT: ${apply_attempt}/${MAX_APPLY_ATTEMPTS}"

  apply_output=$(terraform apply -auto-approve -no-color 2>&1)
  apply_exit=$?
  echo "${apply_output}" | tee -a "${LOG}"

  if [[ ${apply_exit} -eq 0 ]]; then
    log "Terraform apply succeeded on attempt ${apply_attempt}"
    break
  fi

  # Fail fast on errors that retrying cannot fix
  non_transient=$(echo "${apply_output}" | grep -iE "${NON_TRANSIENT_ERRORS}" || true)
  if [[ -n "${non_transient}" ]]; then
    log "ERROR: Non-transient failure on attempt ${apply_attempt}, aborting retries"
    log "Error details:"
    log "${non_transient}"
    log "Check TFC workspace: https://app.terraform.io/app/${TFC_ORG}/workspaces/${WORKSPACE_NAME}"
    exit 1
  fi

  if (( apply_attempt < MAX_APPLY_ATTEMPTS )); then
    log "Transient failure — waiting ${apply_wait}s before retry..."
    log "This is common due to GCP eventual consistency (IAM propagation, API enablement)"
    sleep ${apply_wait}
    apply_wait=$((apply_wait + 30))
    ((apply_attempt++))
  else
    log "ERROR: Terraform apply failed after ${MAX_APPLY_ATTEMPTS} attempts"
    log "Check TFC workspace: https://app.terraform.io/app/${TFC_ORG}/workspaces/${WORKSPACE_NAME}"
    exit 1
  fi
done

log "Infrastructure provisioned successfully"

# --- Extract Outputs ---

log "Extracting terraform outputs..."

# Extract outputs from terraform
# NOTE: Confirmed via TFC documentation that terraform output -json works with
# CLI-driven remote execution and sensitive=true outputs are accessible via CLI.
# The output structure matches the template's output blocks.
terraform output -json > /tmp/tf-outputs.json

# Validate output file is valid JSON
if ! jq empty /tmp/tf-outputs.json 2>/dev/null; then
  log "ERROR: terraform output produced invalid JSON"
  head -20 /tmp/tf-outputs.json | tee -a "${LOG}"
  exit 1
fi

# Write individual outputs to SHARED_DIR for downstream steps
jq -r '.region.value.project_id // empty' /tmp/tf-outputs.json > "${SHARED_DIR}/region-project-id"
jq -r '.region.value.cluster_name // empty' /tmp/tf-outputs.json > "${SHARED_DIR}/region-cluster-name"
jq -r '.management_cluster.value.project_id // empty' /tmp/tf-outputs.json > "${SHARED_DIR}/mc-project-id"
jq -r '.management_cluster.value.cluster_name // empty' /tmp/tf-outputs.json > "${SHARED_DIR}/mc-cluster-name"
jq -r '.management_cluster.value.cluster_endpoint // empty' /tmp/tf-outputs.json > "${SHARED_DIR}/mc-cluster-endpoint"

# Save metadata for deprovision step
echo "${WORKSPACE_NAME}" > "${SHARED_DIR}/workspace-name"
echo "${RUN_ID}" > "${SHARED_DIR}/run-id"

# Validate critical outputs were written
for output_file in region-project-id region-cluster-name mc-project-id mc-cluster-name mc-cluster-endpoint workspace-name run-id; do
  if [[ ! -s "${SHARED_DIR}/${output_file}" ]]; then
    log "ERROR: Output file ${output_file} is empty or missing"
    exit 1
  fi
done

log ""
log "=== Provision Complete ==="
log "  Region Project:   $(<${SHARED_DIR}/region-project-id)"
log "  MC Project:       $(<${SHARED_DIR}/mc-project-id)"
log "  MC Cluster:       $(<${SHARED_DIR}/mc-cluster-name)"
log "  TFC Workspace:    ${WORKSPACE_NAME}"
log "  Run ID:           ${RUN_ID}"
log ""
log "Outputs written to SHARED_DIR for downstream steps"
log "TFC workspace URL: https://app.terraform.io/app/${TFC_ORG}/workspaces/${WORKSPACE_NAME}"
