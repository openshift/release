#!/usr/bin/env bash
set -euo pipefail

LOG="${ARTIFACT_DIR}/cleanup.log"
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') | $*" | tee -a "${LOG}"; }

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

# Read infrastructure info from SHARED_DIR
if [[ ! -f "${SHARED_DIR}/region-project-id" ]]; then
  log "No region-project-id in SHARED_DIR — provision didn't complete, nothing to clean up"
  exit 0
fi

REGION_PROJECT=$(<"${SHARED_DIR}/region-project-id")
REGION_CLUSTER=$(<"${SHARED_DIR}/region-cluster-name")
MC_PROJECT=$(<"${SHARED_DIR}/mc-project-id")
MC_CLUSTER=$(<"${SHARED_DIR}/mc-cluster-name")
REGION=${GCP_REGION:-us-central1}

# Get project numbers
REGION_PROJECT_NUMBER=$(gcloud projects describe "${REGION_PROJECT}" --format='value(projectNumber)' 2>/dev/null || echo "")
MC_PROJECT_NUMBER=$(gcloud projects describe "${MC_PROJECT}" --format='value(projectNumber)' 2>/dev/null || echo "")

log "Infrastructure to clean up:"
log "  Region:  ${REGION_PROJECT} (#${REGION_PROJECT_NUMBER}) / ${REGION_CLUSTER}"
log "  MC:      ${MC_PROJECT} (#${MC_PROJECT_NUMBER}) / ${MC_CLUSTER}"
log "  Region:  ${REGION}"
log ""

# Helper: build kubeconfig with fresh access token using Connect Gateway
build_kubeconfig() {
  local project_number=$1
  local cluster_name=$2
  local output_path=$3

  local endpoint="${REGION}-connectgateway.googleapis.com/v1/projects/${project_number}/locations/${REGION}/gkeMemberships/${cluster_name}"
  local token
  token=$(gcloud auth print-access-token)

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
  output=$(gcloud projects delete "${project}" --quiet 2>&1)
  exit_code=$?
  
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

  # Delete workspace (deletes state)
  local delete_output
  local delete_exit
  delete_output=$(curl -sS -X DELETE \
    --max-time 30 \
    --connect-timeout 10 \
    --header "Authorization: Bearer ${tfc_token}" \
    --header "Content-Type: application/vnd.api+json" \
    "https://app.terraform.io/api/v2/workspaces/${workspace_id}" 2>&1)
  delete_exit=$?
  
  echo "${delete_output}" | tee -a "${LOG}"
  
  if [[ ${delete_exit} -eq 0 ]]; then
    log "  TFC workspace deleted: ${workspace_name}"
  else
    log "  WARNING: Failed to delete TFC workspace (exit code: ${delete_exit}, may already be deleted)"
  fi
}

# ========================================================================
# Execute cleanup
# ========================================================================

# Build kubeconfigs with fresh tokens
REGION_KC="/tmp/region-kubeconfig"
MC_KC="/tmp/mc-kubeconfig"

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

# Phase 5: Force-delete projects (this is the key difference from terraform destroy)
log ""
log "=== Force-deleting GCP projects ==="
log "This bypasses terraform destroy for reliability — project deletion cascades to all resources"
delete_project "${MC_PROJECT}" "MC"
delete_project "${REGION_PROJECT}" "Region"

# Phase 6: Clear TFC workspace state
log ""
clear_tfc_workspace

log ""
log "=== Cleanup complete ==="
log "Projects ${REGION_PROJECT} and ${MC_PROJECT} are now in PENDING_DELETE state (30-day soft delete)"
log "TFC workspace state has been cleared"
