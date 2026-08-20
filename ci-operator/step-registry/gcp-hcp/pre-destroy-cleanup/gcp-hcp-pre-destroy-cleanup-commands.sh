#!/usr/bin/env bash
set -euo pipefail

echo "=== GCP HCP Pre-Destroy Cleanup ==="
echo ""
echo "Removes GCP resources created by ArgoCD-deployed apps that block"
echo "terraform destroy: NEGs (block VPC deletion), DNS records (block"
echo "zone deletion), and Gateway API resources (create NEGs)."
echo ""

# Authenticate with WIF credential
if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "WARNING: WIF credential not found, skipping cleanup"
  exit 0
fi
gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet

# Read cluster info from SHARED_DIR
REGION_PROJECT=$(<"${SHARED_DIR}/region-project-id")
REGION_CLUSTER_NAME=$(<"${SHARED_DIR}/region-cluster-name")
MC_PROJECT=$(<"${SHARED_DIR}/mc-project-id")
MC_CLUSTER_NAME=$(<"${SHARED_DIR}/mc-cluster-name")
REGION=${GCP_REGION:-us-central1}

# Get project numbers for Connect Gateway
REGION_PROJECT_NUMBER=$(gcloud projects describe "${REGION_PROJECT}" --format='value(projectNumber)' 2>/dev/null || echo "")

echo "Region: ${REGION_PROJECT} / ${REGION_CLUSTER_NAME}"
echo "MC:     ${MC_PROJECT} / ${MC_CLUSTER_NAME}"
echo ""

# Build kubeconfigs using Connect Gateway (fresh token — original may have expired)
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

# Helper: run kubectl against a cluster
kc() {
  local kubeconfig=$1
  shift
  kubectl --kubeconfig="${kubeconfig}" "$@"
}

# =====================================================================
# Phase 1: Stop ArgoCD on both clusters
# Prevents ArgoCD from recreating resources we're about to delete
# =====================================================================
stop_argocd() {
  local kubeconfig=$1
  local label=$2

  echo "--- [${label}] Stopping ArgoCD ---"

  # Check if argocd namespace exists
  if ! kc "${kubeconfig}" get namespace argocd &>/dev/null; then
    echo "  ArgoCD namespace not found, skipping"
    return 0
  fi

  # Scale down ArgoCD
  kc "${kubeconfig}" -n argocd scale deployment --all --replicas=0 2>/dev/null || true
  kc "${kubeconfig}" -n argocd scale statefulset --all --replicas=0 2>/dev/null || true

  # Delete all Applications and ApplicationSets (stops app-of-apps)
  kc "${kubeconfig}" -n argocd delete applicationset --all --wait=false --timeout=30s 2>/dev/null || true
  kc "${kubeconfig}" -n argocd delete application --all --wait=false --timeout=30s 2>/dev/null || true

  # Wait briefly for deletions to propagate
  local elapsed=0
  while [[ ${elapsed} -lt 60 ]]; do
    local count
    count=$(kc "${kubeconfig}" -n argocd get applications --no-headers 2>/dev/null | wc -l || echo "0")
    count=$((count + 0))
    if [[ ${count} -eq 0 ]]; then
      echo "  All Applications deleted"
      break
    fi
    echo "  Waiting for ${count} Application(s) to delete... (${elapsed}s)"
    sleep 10
    elapsed=$((elapsed + 10))
  done
}

# =====================================================================
# Phase 2: Delete Gateway API resources (triggers GKE NEG cleanup)
# =====================================================================
delete_gateway_resources() {
  local kubeconfig=$1
  local label=$2

  echo "--- [${label}] Deleting Gateway API resources ---"

  for kind in gcpbackendpolicy healthcheckpolicy httproute gateway; do
    local count
    count=$(kc "${kubeconfig}" get "${kind}" --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    count=$((count + 0))
    if [[ ${count} -gt 0 ]]; then
      echo "  Deleting ${count} ${kind} resource(s)"
      kc "${kubeconfig}" delete "${kind}" --all --all-namespaces --wait=false --timeout=30s 2>/dev/null || true
    fi
  done
}

# =====================================================================
# Phase 3: Delete DNS records from regional zones
# External-dns creates records in the tools zone that block zone deletion
# =====================================================================
delete_dns_records() {
  local project=$1
  local label=$2

  echo "--- [${label}] Cleaning DNS records in ${project} ---"

  local zones
  zones=$(gcloud dns managed-zones list --project="${project}" --format="value(name)" 2>/dev/null || echo "")

  if [[ -z "${zones}" ]]; then
    echo "  No DNS zones found"
    return 0
  fi

  while IFS= read -r zone; do
    [[ -z "${zone}" ]] && continue
    echo "  Zone: ${zone}"

    local records
    records=$(gcloud dns record-sets list \
      --project="${project}" \
      --zone="${zone}" \
      --format="csv[no-heading](name,type)" 2>/dev/null || echo "")

    while IFS=',' read -r name type; do
      [[ -z "${name}" || -z "${type}" ]] && continue
      [[ "${type}" == "SOA" || "${type}" == "NS" ]] && continue
      echo "    Deleting ${type} record: ${name}"
      gcloud dns record-sets delete "${name}" \
        --zone="${zone}" --project="${project}" --type="${type}" \
        --quiet 2>/dev/null || true
    done <<< "${records}"
  done <<< "${zones}"
}

# =====================================================================
# Phase 4: Force-delete remaining NEGs via gcloud
# GKE should clean up NEGs after Gateway deletion, but sometimes
# orphaned NEGs remain and block VPC network deletion.
# =====================================================================
delete_negs() {
  local project=$1
  local label=$2

  echo "--- [${label}] Cleaning up NEGs in ${project} ---"

  # Zonal NEGs
  local negs
  negs=$(gcloud compute network-endpoint-groups list \
    --project="${project}" \
    --format="csv[no-heading](name,zone)" 2>/dev/null || echo "")

  if [[ -z "${negs}" ]]; then
    echo "  No NEGs found"
    return 0
  fi

  while IFS=',' read -r name zone_url; do
    [[ -z "${name}" || -z "${zone_url}" ]] && continue
    # zone_url is a full URL — extract just the zone name
    local zone
    zone=$(basename "${zone_url}")
    echo "  Deleting NEG: ${name} (zone: ${zone})"
    gcloud compute network-endpoint-groups delete "${name}" \
      --project="${project}" --zone="${zone}" \
      --quiet 2>/dev/null || true
  done <<< "${negs}"
}

# =====================================================================
# Execute cleanup on both clusters
# =====================================================================

# Build fresh kubeconfigs (tokens from generate-kubeconfigs may have expired)
CLEANUP_REGION_KC="/tmp/cleanup-region-kubeconfig"
CLEANUP_MC_KC="/tmp/cleanup-mc-kubeconfig"

if [[ -n "${REGION_PROJECT_NUMBER}" ]]; then
  build_kubeconfig "${REGION_PROJECT_NUMBER}" "${REGION_CLUSTER_NAME}" "${CLEANUP_REGION_KC}"

  # MC is registered in region's fleet
  build_kubeconfig "${REGION_PROJECT_NUMBER}" "${MC_CLUSTER_NAME}" "${CLEANUP_MC_KC}"
fi

# Phase 1: Stop ArgoCD (MC first, then region)
if [[ -f "${CLEANUP_MC_KC}" ]]; then
  stop_argocd "${CLEANUP_MC_KC}" "MC" || true
fi
if [[ -f "${CLEANUP_REGION_KC}" ]]; then
  stop_argocd "${CLEANUP_REGION_KC}" "Region" || true
fi

# Phase 2: Delete Gateway API resources
if [[ -f "${CLEANUP_MC_KC}" ]]; then
  delete_gateway_resources "${CLEANUP_MC_KC}" "MC" || true
fi
if [[ -f "${CLEANUP_REGION_KC}" ]]; then
  delete_gateway_resources "${CLEANUP_REGION_KC}" "Region" || true
fi

# Wait for GKE controller to clean up NEGs after Gateway deletion
echo ""
echo "Waiting 60s for GKE to process Gateway/NEG deletions..."
sleep 60

# Phase 3: Delete DNS records from regional zones
delete_dns_records "${REGION_PROJECT}" "Region" || true

# Phase 4: Force-delete remaining NEGs
delete_negs "${REGION_PROJECT}" "Region" || true
delete_negs "${MC_PROJECT}" "MC" || true

# Final NEG check
echo ""
echo "=== Final NEG check ==="
echo "Region:"
gcloud compute network-endpoint-groups list --project="${REGION_PROJECT}" 2>/dev/null || echo "  Unable to list"
echo "MC:"
gcloud compute network-endpoint-groups list --project="${MC_PROJECT}" 2>/dev/null || echo "  Unable to list"

echo ""
echo "=== Pre-destroy cleanup complete ==="
