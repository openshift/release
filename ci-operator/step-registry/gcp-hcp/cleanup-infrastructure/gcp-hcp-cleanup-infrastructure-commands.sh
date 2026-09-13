#!/usr/bin/env bash
set -euo pipefail

LOG="${ARTIFACT_DIR}/cleanup.log"
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') | $*" | tee -a "${LOG}"; }
CLEANUP_FAILED=0

# Validate required dependencies
for cmd in jq gcloud curl; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: ${cmd} not found in container" >&2
    exit 1
  fi
done

# Use oc as kubectl — upi-installer image has oc but not kubectl
if command -v kubectl &>/dev/null; then
  KUBECTL=kubectl
elif command -v oc &>/dev/null; then
  KUBECTL=oc
else
  echo "ERROR: neither kubectl nor oc found in container" >&2
  exit 1
fi

log "=== GCP HCP Infrastructure Cleanup ==="
log "This script performs comprehensive cleanup modeled after the Tekton cleanup task:"
log "1. Stop ArgoCD (prevents resource recreation)"
log "2. Delete Gateway API resources (triggers NEG cleanup)"
log "3. Force-delete NEGs"
log "4. Delete DNS records"
log "5. Delete GCP projects (bypasses terraform destroy for reliability)"
log "6. Clear TFC workspace state"
log ""

# Authenticate with WIF
if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  log "ERROR: WIF credential not found"
  exit 1
fi
gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet

# A lifecycle step may be interrupted before its EXIT trap can remove the
# temporary submitter key. Retry the deletion here as a second cleanup line of
# defense; the key ID contains no credential material.
E2E_HC_SUBMITTER_KEY_ID_FILE="${SHARED_DIR}/e2e-hc-submitter-key-id"
E2E_HC_SUBMITTER_SA="e2e-hc-submitter@gcp-hcp-platform-ci.iam.gserviceaccount.com"
if [[ -s "${E2E_HC_SUBMITTER_KEY_ID_FILE}" ]]; then
  E2E_HC_SUBMITTER_KEY_ID="$(<"${E2E_HC_SUBMITTER_KEY_ID_FILE}")"
  if gcloud iam service-accounts keys delete "${E2E_HC_SUBMITTER_KEY_ID}" \
    --iam-account="${E2E_HC_SUBMITTER_SA}" \
    --quiet; then
    rm -f "${E2E_HC_SUBMITTER_KEY_ID_FILE}"
    log "Removed leaked temporary e2e HC submitter key ${E2E_HC_SUBMITTER_KEY_ID}"
  else
    log "WARNING: Could not remove temporary e2e HC submitter key ${E2E_HC_SUBMITTER_KEY_ID}"
  fi
fi

# Read infrastructure info from SHARED_DIR
if [[ ! -f "${SHARED_DIR}/region-project-id" ]]; then
  log "No region-project-id in SHARED_DIR — provision didn't complete, nothing to clean up"
  exit 0
fi

REGION_PROJECT=$(<"${SHARED_DIR}/region-project-id")
REGION_CLUSTER=$(<"${SHARED_DIR}/region-cluster-name")
MC_PROJECT=$(<"${SHARED_DIR}/mc-project-id")
MC_CLUSTER=$(<"${SHARED_DIR}/mc-cluster-name")
SERVICE_PROJECT=$(cat "${SHARED_DIR}/service-project-id" 2>/dev/null || echo "")
CUSTOMER_PROJECT=$(cat "${SHARED_DIR}/customer-project-id" 2>/dev/null || echo "")
REGION=${GCP_REGION:-us-central1}

# Get project numbers
REGION_PROJECT_NUMBER=$(gcloud projects describe "${REGION_PROJECT}" --format='value(projectNumber)' 2>/dev/null || echo "")
MC_PROJECT_NUMBER=$(gcloud projects describe "${MC_PROJECT}" --format='value(projectNumber)' 2>/dev/null || echo "")

log "Infrastructure to clean up:"
log "  Region:   ${REGION_PROJECT} (#${REGION_PROJECT_NUMBER}) / ${REGION_CLUSTER}"
log "  MC:       ${MC_PROJECT} (#${MC_PROJECT_NUMBER}) / ${MC_CLUSTER}"
if [[ -n "${SERVICE_PROJECT}" ]]; then
  log "  Service:  ${SERVICE_PROJECT}"
fi
if [[ -n "${CUSTOMER_PROJECT}" ]]; then
  log "  Customer: ${CUSTOMER_PROJECT}"
fi
log "  Region:   ${REGION}"
log ""

# Helper: build kubeconfig with fresh access token using Connect Gateway
build_kubeconfig() {
  local project_number=$1
  local cluster_name=$2
  local output_path=$3

  local endpoint="${REGION}-connectgateway.googleapis.com/v1/projects/${project_number}/locations/${REGION}/gkeMemberships/${cluster_name}"
  local token
  token=$(gcloud auth print-access-token)

  (
    umask 077
    cat > "${output_path}" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://${endpoint}
  name: cluster
contexts:
- context:
    cluster: cluster
    user: user
  name: ctx
current-context: ctx
users:
- name: user
  user:
    token: ${token}
EOF
  )
  chmod 600 "${output_path}"
}

# Helper: kubectl/oc wrapper
kc() {
  local kubeconfig=$1
  shift
  "${KUBECTL}" --kubeconfig="${kubeconfig}" "$@"
}

# ========================================================================
# Phase 1: Stop ArgoCD on both clusters
# ========================================================================
stop_argocd() {
  local kubeconfig=$1
  local label=$2

  log "--- [${label}] Stopping ArgoCD ---"

  if ! kc "${kubeconfig}" get namespace argocd &>/dev/null; then
    log "  ArgoCD namespace not found, skipping"
    return 0
  fi

  # Scale down ArgoCD deployments
  kc "${kubeconfig}" -n argocd scale deployment --all --replicas=0 2>/dev/null || true
  kc "${kubeconfig}" -n argocd scale statefulset --all --replicas=0 2>/dev/null || true

  # Delete Applications and ApplicationSets
  kc "${kubeconfig}" -n argocd delete applicationset --all --wait=false --timeout=30s 2>/dev/null || true
  kc "${kubeconfig}" -n argocd delete application --all --wait=false --timeout=30s 2>/dev/null || true

  log "  ArgoCD stopped"
}

# ========================================================================
# Phase 2: Delete Gateway API resources
# ========================================================================
delete_gateway_resources() {
  local kubeconfig=$1
  local label=$2

  log "--- [${label}] Deleting Gateway API resources ---"

  for kind in gcpbackendpolicy healthcheckpolicy httproute gateway; do
    local count
    count=$(kc "${kubeconfig}" get "${kind}" --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    count=$((count + 0))
    if [[ ${count} -gt 0 ]]; then
      log "  Deleting ${count} ${kind} resource(s)"
      kc "${kubeconfig}" delete "${kind}" --all --all-namespaces --wait=false --timeout=30s 2>/dev/null || true
    fi
  done

  # Remove finalizers from stuck Gateway resources
  log "  Removing finalizers from Gateway resources"
  local gateways_json
  if gateways_json=$(kc "${kubeconfig}" get gateway --all-namespaces -o json 2>/dev/null); then
    echo "${gateways_json}" | jq -r '.items[] | select(.metadata.finalizers != null) | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null | \
      while read -r ns name; do
        [[ -z "${ns}" || -z "${name}" ]] && continue
        log "    Patching gateway ${ns}/${name}"
        kc "${kubeconfig}" patch gateway "${name}" -n "${ns}" \
          --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
      done
  else
    log "  WARNING: Could not get Gateway resources (may not exist or cluster unreachable)"
  fi
}

# ========================================================================
# Phase 3: Force-delete NEGs
# ========================================================================
delete_negs() {
  local project=$1
  local label=$2

  log "--- [${label}] Force-deleting NEGs in ${project} ---"

  # Zonal NEGs
  local zones
  zones=$(gcloud compute zones list --filter="region:${REGION}" --format="value(name)" 2>/dev/null || echo "")

  for zone in ${zones}; do
    local negs
    negs=$(gcloud compute network-endpoint-groups list \
      --project="${project}" \
      --zones="${zone}" \
      --format="value(name)" 2>/dev/null || echo "")

    if [[ -n "${negs}" ]]; then
      echo "${negs}" | while read -r neg_name; do
        [[ -z "${neg_name}" ]] && continue
        log "  Deleting zonal NEG: ${neg_name} (zone: ${zone})"
        gcloud compute network-endpoint-groups delete "${neg_name}" \
          --project="${project}" \
          --zone="${zone}" \
          --quiet 2>/dev/null || true
      done
    fi
  done

  # Regional NEGs
  local regional_negs
  regional_negs=$(gcloud compute network-endpoint-groups list \
    --project="${project}" \
    --regions="${REGION}" \
    --format="value(name)" 2>/dev/null || echo "")

  if [[ -n "${regional_negs}" ]]; then
    echo "${regional_negs}" | while read -r neg_name; do
      [[ -z "${neg_name}" ]] && continue
      log "  Deleting regional NEG: ${neg_name}"
      gcloud compute network-endpoint-groups delete "${neg_name}" \
        --project="${project}" \
        --region="${REGION}" \
        --quiet 2>/dev/null || true
    done
  fi
}

# ========================================================================
# Phase 4: Delete DNS records from regional zones
# ========================================================================
delete_dns_records() {
  local project=$1
  local label=$2

  log "--- [${label}] Cleaning DNS records in ${project} ---"

  local zones
  zones=$(gcloud dns managed-zones list --project="${project}" --format="value(name)" 2>/dev/null || echo "")

  if [[ -z "${zones}" ]]; then
    log "  No DNS zones found"
    return 0
  fi

  while IFS= read -r zone; do
    [[ -z "${zone}" ]] && continue
    # Skip GKE Cloud DNS Scope zones (internal cluster DNS) — deleted with the cluster
    if [[ "${zone}" == gke-* ]]; then
      log "  Skipping GKE internal zone: ${zone}"
      continue
    fi
    log "  Zone: ${zone}"

    local records
    records=$(gcloud dns record-sets list \
      --project="${project}" \
      --zone="${zone}" \
      --format="csv[no-heading](name,type)" 2>/dev/null || echo "")

    while IFS=',' read -r name type; do
      [[ -z "${name}" || -z "${type}" ]] && continue
      [[ "${type}" == "SOA" || "${type}" == "NS" ]] && continue
      log "    Deleting ${type} record: ${name}"
      gcloud dns record-sets delete "${name}" \
        --zone="${zone}" --project="${project}" --type="${type}" \
        --quiet 2>/dev/null || true
    done <<< "${records}"
  done <<< "${zones}"
}

# ========================================================================
# Phase 5: Force-delete GCP projects
# ========================================================================
delete_project() {
  local project=$1
  local label=$2

  log "--- [${label}] Force-deleting project: ${project} ---"

  local output
  local exit_code
  if output=$(gcloud projects delete "${project}" --quiet 2>&1); then
    exit_code=0
  else
    exit_code=$?
  fi
  
  echo "${output}" | tee -a "${LOG}"
  
  if [[ ${exit_code} -eq 0 ]]; then
    log "  Project ${project} deletion initiated"
    return 0
  else
    log "  ERROR: Failed to delete project ${project} (exit code: ${exit_code})"
    return 1
  fi
}

# ========================================================================
# Phase 6: Clear TFC workspace state
# ========================================================================
clear_tfc_workspace() {
  log "--- Clearing TFC workspace state ---"

  # Read workspace info from SHARED_DIR
  if [[ ! -f "${SHARED_DIR}/workspace-name" ]]; then
    log "  WARNING: No workspace-name in SHARED_DIR, skipping TFC cleanup"
    return 0
  fi

  local workspace_name
  workspace_name=$(<"${SHARED_DIR}/workspace-name")

  if [[ ! -f "/etc/terraform-cloud/token" ]]; then
    log "  WARNING: TFC token not found, skipping TFC cleanup"
    return 0
  fi

  local tfc_token
  tfc_token=$(<"/etc/terraform-cloud/token")
  local tfc_org="${TFC_ORGANIZATION:-hp-platform-engineering}"

  log "  Workspace: ${workspace_name}"

  # Get workspace ID
  local workspace_id
  workspace_id=$(curl -sS \
    --max-time 30 \
    --connect-timeout 10 \
    --header "Authorization: Bearer ${tfc_token}" \
    --header "Content-Type: application/vnd.api+json" \
    "https://app.terraform.io/api/v2/organizations/${tfc_org}/workspaces/${workspace_name}" 2>/dev/null | \
    jq -r '.data.id // empty' 2>/dev/null || echo "")

  if [[ -z "${workspace_id}" ]]; then
    log "  WARNING: Could not find workspace ID, may already be deleted"
    return 0
  fi

  # Use terraform CLI to clear state, then safe-delete the workspace.
  # The GCP projects are already deleted, so the state is stale.
  # Install terraform, point it at the TFC workspace via cloud backend,
  # and run 'terraform state rm' at the module level for speed (~3s for 400+ resources).

  # Install terraform (same version as .tool-versions)
  # Read terraform version from the TFC workspace to avoid version mismatch
  # errors. The workspace was created by tf-provision with whatever version
  # .tool-versions specifies — the cleanup must use the same version.
  local tf_version
  tf_version=$(curl -sS --max-time 10 \
    --header "Authorization: Bearer ${tfc_token}" \
    "https://app.terraform.io/api/v2/organizations/${tfc_org}/workspaces/${workspace_name}" 2>/dev/null | \
    jq -r '.data.attributes["terraform-version"] // empty' 2>/dev/null || echo "")
  if [[ -z "${tf_version}" ]]; then
    tf_version="1.16.0"
    log "  WARNING: Could not read workspace terraform version, using ${tf_version}"
  fi
  log "  Installing terraform ${tf_version}..."
  if ! curl -fsSL --max-time 120 \
    "https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_amd64.zip" \
    -o /tmp/terraform.zip; then
    log "  ERROR: Failed to download terraform; TFC cleanup is incomplete"
    CLEANUP_FAILED=1
    return 0
  fi
  if command -v unzip &>/dev/null; then
    unzip -o -q /tmp/terraform.zip -d /tmp
  else
    python3 -c "import zipfile; zipfile.ZipFile('/tmp/terraform.zip').extractall('/tmp')"
  fi
  chmod +x /tmp/terraform

  # Create minimal terraform config with cloud backend
  local tf_dir="/tmp/tfc-cleanup"
  mkdir -p "${tf_dir}"
  cat > "${tf_dir}/main.tf" <<TFEOF
terraform {
  cloud {
    organization = "${tfc_org}"
    workspaces {
      name = "${workspace_name}"
    }
  }
}
TFEOF

  # Configure TFC auth
  (umask 077 && cat > "$HOME/.terraformrc" <<TFRC
credentials "app.terraform.io" {
  token = "${tfc_token}"
}
TFRC
  )

  export TF_INPUT=false
  export TF_IN_AUTOMATION=true

  log "  Initializing terraform against workspace ${workspace_name}..."
  if ! /tmp/terraform -chdir="${tf_dir}" init -no-color 2>&1 | tee -a "${LOG}"; then
    log "  ERROR: terraform init failed; TFC cleanup is incomplete"
    CLEANUP_FAILED=1
    return 0
  fi

  # Force-unlock if the workspace is locked from a previous run
  local lock_id
  lock_id=$(/tmp/terraform -chdir="${tf_dir}" state list -no-color 2>&1 | \
    grep -oP 'lock ID: "\K[^"]+' || echo "")
  if [[ -n "${lock_id}" ]]; then
    log "  Workspace locked (${lock_id}), force-unlocking..."
    /tmp/terraform -chdir="${tf_dir}" force-unlock -force "${lock_id}" -no-color 2>&1 | tee -a "${LOG}" || true
  fi

  # Remove all resources from state in one bulk operation.
  # E2E state has 3 top-level modules plus data sources. Removing at
  # module level clears child resources, then we remove any remaining
  # top-level resources (data sources).
  log "  Clearing all resources from state..."
  local state_resources
  if ! state_resources=$(/tmp/terraform -chdir="${tf_dir}" state list -no-color 2>>"${LOG}"); then
    log "  ERROR: Could not read TFC state; refusing force-delete"
    CLEANUP_FAILED=1
    return 0
  fi
  local resource_count
  resource_count=0
  if [[ -n "${state_resources}" ]]; then
    resource_count=$(printf '%s\n' "${state_resources}" | wc -l | tr -d ' ')
  fi
  local state_rm_succeeded=true

  if [[ ${resource_count} -eq 0 ]]; then
    log "  State is already empty"
  else
    log "  Removing ${resource_count} resources..."
    # Remove top-level modules in one bulk operation. This is intentionally
    # the fast path: removing a module address removes all of its children
    # without making one backend request per resource.
    local module_addresses
    module_addresses=$(printf '%s\n' "${state_resources}" | \
      sed -n -E 's/^(module\.[^.]+)\..*/\1/p' | sort -u)
    if [[ -n "${module_addresses}" ]]; then
      log "  Removing modules: ${module_addresses//$'\n'/, }"
      local -a module_address_list
      mapfile -t module_address_list < <(printf '%s\n' "${module_addresses}")
      if ! printf '%s\0' "${module_address_list[@]}" | \
        xargs -0 -r -n 100 /tmp/terraform -chdir="${tf_dir}" state rm -no-color >>"${LOG}" 2>&1; then
        log "  WARNING: module-level state removal was incomplete; sweeping exact addresses"
      fi
    fi

    # The module fast path does not cover top-level resources or data sources,
    # and it may leave unusual indexed addresses behind. Re-read state and
    # remove every remaining address exactly, preserving quoted keys.
    local state_after_modules
    if ! state_after_modules=$(/tmp/terraform -chdir="${tf_dir}" state list -no-color 2>>"${LOG}"); then
      log "  ERROR: Could not read TFC state after module removal"
      state_rm_succeeded=false
      CLEANUP_FAILED=1
    elif [[ -n "${state_after_modules}" ]]; then
      local -a remaining_addresses
      mapfile -t remaining_addresses < <(printf '%s\n' "${state_after_modules}")
      log "  Sweeping ${#remaining_addresses[@]} remaining exact state address(es)..."
      if ! printf '%s\0' "${remaining_addresses[@]}" | \
        xargs -0 -r -n 100 /tmp/terraform -chdir="${tf_dir}" state rm -no-color >>"${LOG}" 2>&1; then
        log "  ERROR: exact state sweep failed; workspace may not be safe-deletable"
        state_rm_succeeded=false
        CLEANUP_FAILED=1
      fi
    fi
  fi

  # The state version created by `terraform state rm` is committed
  # asynchronously by HCP Terraform. Give the backend time to report an empty
  # state before attempting safe-delete. This also catches resources that
  # could not be removed.
  local state_empty=false
  local state_after_rm
  local state_attempt
  for state_attempt in {1..12}; do
    if state_after_rm=$(/tmp/terraform -chdir="${tf_dir}" state list -no-color 2>>"${LOG}"); then
      if [[ -z "${state_after_rm}" ]]; then
        state_empty=true
        break
      fi
      log "  TFC state still contains resources after removal (attempt ${state_attempt}/12)"
    else
      log "  WARNING: Could not verify TFC state after removal (attempt ${state_attempt}/12)"
    fi
    sleep 5
  done

  if [[ "${state_rm_succeeded}" != "true" || "${state_empty}" != "true" ]]; then
    log "  ERROR: TFC state is not empty; refusing force-delete"
    log "  Workspace: https://app.terraform.io/app/${tfc_org}/workspaces/${workspace_name}"
    CLEANUP_FAILED=1
    return 0
  fi

  # Safe-delete may still briefly return 409 while the empty state version
  # propagates through HCP Terraform. Retry with bounded backoff before using
  # the force-delete endpoint as a last resort.
  log "  Deleting workspace..."
  local http_code
  local delete_attempt
  local safe_delete_succeeded=false
  local safe_delete_conflict=false
  for delete_attempt in {1..6}; do
    if http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
      --max-time 30 \
      --connect-timeout 10 \
      --header "Authorization: Bearer ${tfc_token}" \
      --header "Content-Type: application/vnd.api+json" \
      --request POST \
      "https://app.terraform.io/api/v2/workspaces/${workspace_id}/actions/safe-delete" 2>>"${LOG}"); then
      if [[ "${http_code}" == "204" || "${http_code}" == "200" || "${http_code}" == "404" ]]; then
        safe_delete_succeeded=true
        break
      fi
      if [[ "${http_code}" == "409" ]]; then
        safe_delete_conflict=true
        log "  Workspace state is still propagating (safe-delete HTTP 409, attempt ${delete_attempt}/6)"
      else
        safe_delete_conflict=false
        log "  ERROR: Could not safe-delete TFC workspace (HTTP ${http_code})"
        break
      fi
    else
      safe_delete_conflict=false
      log "  ERROR: TFC workspace safe-delete request failed"
      break
    fi
    if [[ ${delete_attempt} -lt 6 ]]; then
      sleep $((5 * (2 ** (delete_attempt - 1))))
    fi
  done

  if [[ "${safe_delete_succeeded}" == "true" ]]; then
    log "  TFC workspace deleted: ${workspace_name}"
    return 0
  fi

  if [[ "${safe_delete_conflict}" != "true" ]]; then
    log "  ERROR: TFC workspace safe-delete did not return a retryable conflict"
    log "  Workspace: https://app.terraform.io/app/${tfc_org}/workspaces/${workspace_name}"
    CLEANUP_FAILED=1
    return 0
  fi

  # We have already deleted the GCP projects and verified that the remote
  # state is empty. Force-delete only in this narrow case; unlike safe-delete,
  # this endpoint requires org-owner/workspace-admin permission and does not
  # destroy managed infrastructure.
  log "  WARNING: safe-delete did not complete; attempting force-delete"
  if http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    --max-time 30 \
    --connect-timeout 10 \
    --header "Authorization: Bearer ${tfc_token}" \
    --header "Content-Type: application/vnd.api+json" \
    --request DELETE \
    "https://app.terraform.io/api/v2/workspaces/${workspace_id}" 2>>"${LOG}"); then
    if [[ "${http_code}" == "204" || "${http_code}" == "200" || "${http_code}" == "404" ]]; then
      log "  TFC workspace deleted: ${workspace_name}"
      return 0
    fi
    if [[ "${http_code}" == "403" ]]; then
      log "  ERROR: TFC force-delete is not permitted for this token (HTTP 403)"
    else
      log "  ERROR: Could not force-delete TFC workspace (HTTP ${http_code})"
    fi
  else
    log "  ERROR: TFC workspace force-delete request failed"
  fi
  log "  Workspace: https://app.terraform.io/app/${tfc_org}/workspaces/${workspace_name}"
  CLEANUP_FAILED=1
}

# ========================================================================
# Execute cleanup
# ========================================================================

# Build kubeconfigs with fresh tokens. Keep them private and remove them on
# every exit path because they contain live access tokens.
REGION_KC=""
MC_KC=""
cleanup_kubeconfigs() {
  [[ -z "${REGION_KC}" ]] || rm -f "${REGION_KC}"
  [[ -z "${MC_KC}" ]] || rm -f "${MC_KC}"
}
trap cleanup_kubeconfigs EXIT
REGION_KC="$(mktemp "${TMPDIR:-/tmp}/gcp-hcp-region-kubeconfig.XXXXXX")"
MC_KC="$(mktemp "${TMPDIR:-/tmp}/gcp-hcp-mc-kubeconfig.XXXXXX")"

if [[ -n "${REGION_PROJECT_NUMBER}" ]]; then
  build_kubeconfig "${REGION_PROJECT_NUMBER}" "${REGION_CLUSTER}" "${REGION_KC}"
  # MC is registered in region's fleet
  build_kubeconfig "${REGION_PROJECT_NUMBER}" "${MC_CLUSTER}" "${MC_KC}"
fi

# Verify connectivity
log "Verifying cluster connectivity..."
REGION_CONNECTED=false
MC_CONNECTED=false

if [[ -f "${REGION_KC}" ]] && kc "${REGION_KC}" get nodes --request-timeout=10s &>/dev/null; then
  log "  Region cluster: connected"
  REGION_CONNECTED=true
else
  log "  Region cluster: unreachable"
fi

if [[ -f "${MC_KC}" ]] && kc "${MC_KC}" get nodes --request-timeout=10s &>/dev/null; then
  log "  MC cluster: connected"
  MC_CONNECTED=true
else
  log "  MC cluster: unreachable"
fi
log ""

# Phase 1: Stop ArgoCD (MC first, then region)
if [[ "${MC_CONNECTED}" == "true" ]]; then
  stop_argocd "${MC_KC}" "MC" || true
fi
if [[ "${REGION_CONNECTED}" == "true" ]]; then
  stop_argocd "${REGION_KC}" "Region" || true
fi

# Phase 2: Delete Gateway API resources
if [[ "${MC_CONNECTED}" == "true" ]]; then
  delete_gateway_resources "${MC_KC}" "MC" || true
fi
if [[ "${REGION_CONNECTED}" == "true" ]]; then
  delete_gateway_resources "${REGION_KC}" "Region" || true
fi

# Wait for GKE Gateway controller to process deletions
# Note: 120s is a conservative estimate. GKE typically processes Gateway deletions
# within 60s, but we add buffer time to reduce NEG orphan risk. This wait can be
# tuned based on observed cleanup times.
if [[ "${REGION_CONNECTED}" == "true" || "${MC_CONNECTED}" == "true" ]]; then
  log ""
  log "Waiting 120s for GKE to process Gateway/NEG deletions..."
  sleep 120
fi

# Phase 3: Force-delete remaining NEGs
delete_negs "${REGION_PROJECT}" "Region" || true
delete_negs "${MC_PROJECT}" "MC" || true

# Phase 4: Delete DNS records
delete_dns_records "${REGION_PROJECT}" "Region" || true

# Phase 4b: Delete Cloud Endpoints services (blocks project deletion)
if [[ -n "${SERVICE_PROJECT}" ]]; then
  log "--- Deleting Cloud Endpoints service in ${SERVICE_PROJECT} ---"
  gcloud endpoints services delete "hcp-api.endpoints.${SERVICE_PROJECT}.cloud.goog" --project="${SERVICE_PROJECT}" --quiet 2>/dev/null || true
fi

# Phase 5: Force-delete projects (this is the key difference from terraform destroy)
log ""
log "=== Force-deleting GCP projects ==="
log "This bypasses terraform destroy for reliability — project deletion cascades to all resources"
delete_project "${MC_PROJECT}" "MC" || CLEANUP_FAILED=1
delete_project "${REGION_PROJECT}" "Region" || CLEANUP_FAILED=1
if [[ -n "${SERVICE_PROJECT}" ]]; then
  delete_project "${SERVICE_PROJECT}" "Service" || CLEANUP_FAILED=1
fi
if [[ -n "${CUSTOMER_PROJECT}" ]]; then
  delete_project "${CUSTOMER_PROJECT}" "Customer" || CLEANUP_FAILED=1
fi

# Phase 6: Clear TFC workspace state
log ""
clear_tfc_workspace || CLEANUP_FAILED=1

log ""
if [[ "${CLEANUP_FAILED}" -ne 0 ]]; then
  log "=== Cleanup completed with errors ==="
  log "One or more resources could not be cleaned up; manual cleanup may be required"
  exit 1
fi

log "=== Cleanup complete ==="
log "Projects are now in PENDING_DELETE state (30-day soft delete)"
log "TFC workspace state has been cleared"
