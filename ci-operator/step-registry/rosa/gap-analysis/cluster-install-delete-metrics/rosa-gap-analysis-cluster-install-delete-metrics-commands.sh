#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

error(){
    echo -e "\033[1;31m$(date "+%d-%m-%YT%H:%M:%S") ERROR: " "${*}\033[0m" >&2
}

success(){
    echo -e "\033[1;32m$(date "+%d-%m-%YT%H:%M:%S") SUCCESS: " "${*}\033[0m" >&2
}

# Keep raw JSON payloads out of the published artifacts. Callers must check
# this function's status before using the JSON as health evidence.
get_resource_json(){
  local resource="$1" dest="$2"
  oc get "${resource}" -o json --request-timeout=60s > "${dest}" 2>/dev/null || return 1
  jq -e 'has("items") and (.items | type == "array") and all(.items[]; type == "object")' \
    "${dest}" >/dev/null 2>&1
}

# Configure cloud credentials. OSD GCP does not use AWS.
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ "${CLUSTER_TOPOLOGY:-}" == "osd-gcp" ]]; then
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE:-}}"
  log "OSD GCP cluster; skipping AWS credential setup"
elif [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE:-}}"
  if [[ -z "${AWS_DEFAULT_REGION}" ]]; then
    error "No AWS region: set REGION or LEASED_RESOURCE"
    exit 1
  fi
else
  error "No AWS credentials found in cluster profile"
  exit 1
fi

# Log into OCM
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  error "No OCM credentials found in cluster profile"
  exit 1
fi

# Get cluster info
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Running gap-analysis validation for cluster: ${CLUSTER_ID}"

if [[ "${HOSTED_CP:-false}" == "true" ]]; then
  topology="hcp"
elif [[ "${CLUSTER_TOPOLOGY:-}" == "osd-gcp" ]]; then
  topology="osd-gcp"
else
  topology="classic"
fi

DIAG_DIR="${ARTIFACT_DIR}/diagnostics"
mkdir -p "${DIAG_DIR}"

# JSON payloads are temporary working data, never artifacts.
VALIDATION_SCRATCH="$(mktemp -d)"
trap 'rm -rf -- "${VALIDATION_SCRATCH}"' EXIT

# Initialize validation report
INSTALL_REPORT="${DIAG_DIR}/gap-analysis-cluster-install-report.txt"

cat > "${INSTALL_REPORT}" <<EOF
========================================
ROSA Gap Analysis Cluster Install Report
========================================
Cluster ID: ${CLUSTER_ID}
Region: ${AWS_DEFAULT_REGION}
Test Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
========================================

EOF

VALIDATION_FAILED=0

# Verify cluster exists via OCM API
log "Verifying cluster exists..."
if ! ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}" &>/dev/null; then
  error "Failed to get cluster ${CLUSTER_ID} from OCM API"
  exit 1
fi

KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

# Use existing kubeconfig if present (created by rosa-conf-idp-htpasswd in PRE phase)
if [[ -f "${KUBECONFIG_FILE}" ]]; then
  log "Using existing admin kubeconfig from PRE phase"
  export KUBECONFIG="${KUBECONFIG_FILE}"
else
  # Fallback: fetch kubeconfig via OCM API
  log "No existing kubeconfig found, fetching from OCM API..."
  ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/credentials 2>/dev/null | jq -r '.kubeconfig' > "${KUBECONFIG_FILE}" || {
    error "Failed to fetch kubeconfig via OCM API"
    exit 1
  }
  export KUBECONFIG="${KUBECONFIG_FILE}"
fi

# Validate kubeconfig
if ! oc whoami &>/dev/null; then
  error "Failed to authenticate with cluster kubeconfig"
  exit 1
fi

log "Successfully authenticated with cluster"

###########################################
# Validation 1: Validate ClusterOperators
###########################################
log "Validation 1: Validating ClusterOperators..."
echo "" >> "${INSTALL_REPORT}"
echo "1. ClusterOperators Status" >> "${INSTALL_REPORT}"
echo "--------------------------" >> "${INSTALL_REPORT}"

CO_OUTPUT="${DIAG_DIR}/clusteroperators.txt"
CO_JSON="${VALIDATION_SCRATCH}/clusteroperators.json"
CO_WIDE_OK=0
CO_JSON_OK=0
if oc get co -o wide > "${CO_OUTPUT}" 2>/dev/null; then
  CO_WIDE_OK=1
  cat "${CO_OUTPUT}" >> "${INSTALL_REPORT}"
  echo "" >> "${INSTALL_REPORT}"
else
  echo "(ClusterOperator listing unavailable)" > "${CO_OUTPUT}"
  error "Failed to get ClusterOperators"
  echo "Status: FAILED (unable to retrieve ClusterOperators)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
fi

if ! get_resource_json co "${CO_JSON}"; then
  error "Failed to query ClusterOperators as JSON; operator health is unverified"
  echo "Status: FAILED (ClusterOperator JSON query failed or returned malformed data)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
else
  CO_JSON_OK=1
  # Check for degraded or unavailable operators
  CO_COUNT=$(jq -r '.items | length' "${CO_JSON}")
  DEGRADED_CO=$(jq -r '.items[]? | select(any(.status.conditions[]?; .type=="Degraded" and .status=="True")) | .metadata.name' "${CO_JSON}")
  UNAVAILABLE_CO=$(jq -r '.items[]? | select(any(.status.conditions[]?; .type=="Available" and .status=="False")) | .metadata.name' "${CO_JSON}")

  if [[ -n "${DEGRADED_CO}" ]]; then
    error "Degraded ClusterOperators found: ${DEGRADED_CO}"
    echo "Degraded Operators: ${DEGRADED_CO}" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ -n "${UNAVAILABLE_CO}" ]]; then
    error "Unavailable ClusterOperators found: ${UNAVAILABLE_CO}"
    echo "Unavailable Operators: ${UNAVAILABLE_CO}" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ "${CO_COUNT}" -eq 0 ]]; then
    error "ClusterOperator query returned no operators; operator health is unverified"
    echo "Status: FAILED (no ClusterOperators returned)" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  elif [[ -z "${DEGRADED_CO}" && -z "${UNAVAILABLE_CO}" && "${CO_WIDE_OK}" -eq 1 ]]; then
    success "All ClusterOperators are healthy"
    echo "All operators: HEALTHY" >> "${INSTALL_REPORT}"
  fi
fi

###########################################
# Validation 2: Validate nodes
###########################################
log "Validation 2: Validating nodes..."
echo "" >> "${INSTALL_REPORT}"
echo "2. Nodes Status" >> "${INSTALL_REPORT}"
echo "---------------" >> "${INSTALL_REPORT}"

NODES_OUTPUT="${DIAG_DIR}/nodes.txt"
NODES_JSON="${VALIDATION_SCRATCH}/nodes.json"
NODES_WIDE_OK=0
NODES_JSON_OK=0
if oc get nodes -o wide > "${NODES_OUTPUT}" 2>/dev/null; then
  NODES_WIDE_OK=1
  cat "${NODES_OUTPUT}" >> "${INSTALL_REPORT}"
  echo "" >> "${INSTALL_REPORT}"
else
  echo "(node listing unavailable)" > "${NODES_OUTPUT}"
  error "Failed to get nodes"
  echo "Status: FAILED (unable to retrieve nodes)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
fi

if ! get_resource_json nodes "${NODES_JSON}"; then
  error "Failed to query nodes as JSON; node health is unverified"
  echo "Status: FAILED (node JSON query failed or returned malformed data)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
else
  NODES_JSON_OK=1
  # Check for NotReady nodes
  NODE_COUNT=$(jq -r '.items | length' "${NODES_JSON}")
  NOTREADY_NODES=$(jq -r '.items[]? | select(any(.status.conditions[]?; .type=="Ready" and .status!="True")) | .metadata.name' "${NODES_JSON}")

  if [[ "${NODE_COUNT}" -eq 0 ]]; then
    error "Node query returned no nodes; node health is unverified"
    echo "Status: FAILED (no nodes returned)" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  elif [[ -n "${NOTREADY_NODES}" ]]; then
    error "NotReady nodes found: ${NOTREADY_NODES}"
    echo "NotReady Nodes: ${NOTREADY_NODES}" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  elif [[ "${NODES_WIDE_OK}" -eq 1 ]]; then
    success "All nodes are Ready"
    echo "All nodes: READY" >> "${INSTALL_REPORT}"
  fi

  # Count nodes
  echo "Total nodes: ${NODE_COUNT}" >> "${INSTALL_REPORT}"
fi

###########################################
# Collect cluster logs (always)
# HCP control-plane pods live on the management cluster in HCP_NAMESPACE.
# Guest-side openshift-cluster-version / kube-apiserver / etcd are empty on HCP.
###########################################
log "Collecting cluster logs and diagnostics..."
echo "" >> "${INSTALL_REPORT}"
echo "3. Cluster Logs and Diagnostics" >> "${INSTALL_REPORT}"
echo "--------------------------------" >> "${INSTALL_REPORT}"

if [[ "${topology}" != "hcp" ]]; then
  log "Collecting cluster-version operator logs..."
  oc logs deployment/cluster-version-operator -n openshift-cluster-version --tail=500 > "${DIAG_DIR}/cvo-logs.txt" 2>&1 || true
fi

if [[ -n "${DEGRADED_CO:-}" ]]; then
  for co in ${DEGRADED_CO}; do
    log "Collecting logs for degraded operator: ${co}"
    oc describe co "${co}" > "${DIAG_DIR}/co-${co}-describe.txt" 2>&1 || true
  done
fi

if [[ "${topology}" == "hcp" ]]; then
  log "HCP guest: collecting worker-side monitoring pods (control plane is on the management cluster)"
  oc get pods -n openshift-monitoring -o wide > "${DIAG_DIR}/pods-openshift-monitoring.txt" 2>&1 || true
else
  for ns in openshift-cluster-version openshift-kube-apiserver openshift-etcd openshift-monitoring; do
    log "Collecting pod status from namespace: ${ns}"
    oc get pods -n "${ns}" -o wide > "${DIAG_DIR}/pods-${ns}.txt" 2>&1 || true
  done
fi

echo "Cluster logs collected in ${DIAG_DIR}/" >> "${INSTALL_REPORT}"

###########################################
# Structured snapshot for rosa-gap-analysis Check #11
###########################################

ensure_management_cluster_ids() {
  if [[ -f "${SHARED_DIR}/mc-cluster-name" && -f "${SHARED_DIR}/mc-cluster-id" ]]; then
    return 0
  fi
  local mc_name mc_id
  mc_name="$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard" | jq -r '.management_cluster')" || return 0
  if [[ -z "${mc_name}" || "${mc_name}" == "null" ]]; then
    return 0
  fi
  echo "${mc_name}" > "${SHARED_DIR}/mc-cluster-name"
  mc_id="$(ocm get /api/clusters_mgmt/v1/clusters --parameter "search=name is '${mc_name}'" | jq -r '.items[0].id')" || return 0
  if [[ -n "${mc_id}" && "${mc_id}" != "null" ]]; then
    echo "${mc_id}" > "${SHARED_DIR}/mc-cluster-id"
  fi
}

resolve_management_kubeconfig() {
  local mc_file="${SHARED_DIR}/hs-mc.kubeconfig"
  if [[ -f "${mc_file}" ]]; then
    log "Using management kubeconfig from ${mc_file}"
    ensure_management_cluster_ids
    export KUBECONFIG="${mc_file}"
    return 0
  fi
  log "Resolving management cluster for hosted cluster ${CLUSTER_ID}"
  local mc_name mc_id
  mc_name="$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard" | jq -r '.management_cluster')" || return 1
  mc_id="$(ocm get /api/clusters_mgmt/v1/clusters --parameter "search=name is '${mc_name}'" | jq -r '.items[0].id')" || return 1
  if [[ -z "${mc_id}" || "${mc_id}" == "null" ]]; then
    error "Failed to get management cluster id for ${mc_name}"
    return 1
  fi
  echo "${mc_name}" > "${SHARED_DIR}/mc-cluster-name"
  echo "${mc_id}" > "${SHARED_DIR}/mc-cluster-id"
  log "Fetching management kubeconfig for ${mc_name} (${mc_id})"
  ocm get "/api/clusters_mgmt/v1/clusters/${mc_id}/credentials" | jq -r '.kubeconfig' > "${mc_file}" || return 1
  export KUBECONFIG="${mc_file}"
}

# Hosted control plane namespace on the management cluster:
#   HC_NAMESPACE  = ocm-<env>-<hosted CLUSTER_ID>
#   HCP_NAMESPACE = ocm-<env>-<hosted CLUSTER_ID>-<DOMAIN_PREFIX>
# env is OCM_LOGIN_ENV (staging/production). DOMAIN_PREFIX comes from the hosted cluster.
resolve_hcp_namespaces() {
  local cluster_info domain_prefix
  cluster_info="$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}")" || return 1
  domain_prefix="$(echo "${cluster_info}" | jq -r '.domain_prefix // empty')"
  if [[ -z "${domain_prefix}" || "${domain_prefix}" == "null" ]]; then
    if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
      domain_prefix="$(head -n 1 "${SHARED_DIR}/cluster-name")"
    else
      domain_prefix="$(echo "${cluster_info}" | jq -r '.name')"
    fi
  fi
  if [[ -z "${domain_prefix}" || "${domain_prefix}" == "null" ]]; then
    error "Failed to resolve hosted cluster domain prefix for ${CLUSTER_ID}"
    return 1
  fi
  HC_NAMESPACE="ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}"
  HCP_NAMESPACE="ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-${domain_prefix}"
  log "HC namespace:  ${HC_NAMESPACE}"
  log "HCP namespace: ${HCP_NAMESPACE}"
}

collect_hcp_control_plane_diagnostics() {
  if ! resolve_hcp_namespaces; then
    return 0
  fi
  mkdir -p "${DIAG_DIR}"
  log "Collecting hosted control-plane pods from management cluster namespace ${HCP_NAMESPACE}"
  oc get hostedcluster -n "${HC_NAMESPACE}" -o wide > "${DIAG_DIR}/hostedcluster.txt" 2>&1 || true
  oc get hostedcontrolplane -n "${HCP_NAMESPACE}" -o wide > "${DIAG_DIR}/hostedcontrolplane.txt" 2>&1 || true
  oc get pods -n "${HCP_NAMESPACE}" -o wide > "${DIAG_DIR}/pods-hcp-namespace.txt" 2>&1 || true
  oc logs deployment/cluster-version-operator -n "${HCP_NAMESPACE}" --tail=500 > "${DIAG_DIR}/cvo-logs.txt" 2>&1 || \
    oc logs -n "${HCP_NAMESPACE}" -l app=cluster-version-operator --tail=500 > "${DIAG_DIR}/cvo-logs.txt" 2>&1 || true
  echo "HCP namespace ${HCP_NAMESPACE} pods collected from management cluster" >> "${INSTALL_REPORT}"
}

write_install_snapshot() {
  local cluster_role="$1"
  local snapshot_dir="$2"
  local overall_status="$3"
  mkdir -p "${snapshot_dir}"

  local snapshot_co_json snapshot_nodes_json
  local node_count degraded_raw unavailable_raw notready_raw
  if [[ "${overall_status}" == "INFO" ]]; then
    snapshot_co_json="${VALIDATION_SCRATCH}/${cluster_role}-clusteroperators.json"
    snapshot_nodes_json="${VALIDATION_SCRATCH}/${cluster_role}-nodes.json"
    if ! get_resource_json co "${snapshot_co_json}"; then
      echo '{"items":[]}' > "${snapshot_co_json}"
    fi
    if ! get_resource_json nodes "${snapshot_nodes_json}"; then
      echo '{"items":[]}' > "${snapshot_nodes_json}"
    fi

    node_count="$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
    [[ "${node_count}" =~ ^[0-9]+$ ]] || node_count=0
    degraded_raw="$(jq -r '.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name' "${snapshot_co_json}" 2>/dev/null || true)"
    unavailable_raw="$(jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' "${snapshot_co_json}" 2>/dev/null || true)"
    notready_raw="$(jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status!="True")) | .metadata.name' "${snapshot_nodes_json}" 2>/dev/null || true)"
  else
    if [[ "${CO_JSON_OK:-0}" -ne 1 || "${NODES_JSON_OK:-0}" -ne 1 ]]; then
      error "Cannot write ${cluster_role} snapshot without validated ClusterOperator and node JSON"
      VALIDATION_FAILED=1
      return 1
    fi
    snapshot_co_json="${CO_JSON}"
    snapshot_nodes_json="${NODES_JSON}"
    node_count="${NODE_COUNT}"
    degraded_raw="${DEGRADED_CO:-}"
    unavailable_raw="${UNAVAILABLE_CO:-}"
    notready_raw="${NOTREADY_NODES:-}"
  fi

  local cluster_version=""
  cluster_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' --request-timeout=30s 2>/dev/null || true)"
  local mgmt_name="" mgmt_id=""
  if [[ -f "${SHARED_DIR}/mc-cluster-name" ]]; then
    mgmt_name="$(cat "${SHARED_DIR}/mc-cluster-name")"
  fi
  if [[ -f "${SHARED_DIR}/mc-cluster-id" ]]; then
    mgmt_id="$(cat "${SHARED_DIR}/mc-cluster-id")"
  fi

  local snapshot_cluster_id snapshot_openshift_version
  snapshot_cluster_id="${CLUSTER_ID}"
  snapshot_openshift_version="${OPENSHIFT_VERSION:-}"
  if [[ "${cluster_role}" == "management" ]]; then
    snapshot_cluster_id="${mgmt_id:-${CLUSTER_ID}}"
    if [[ "${cluster_version}" =~ ^([0-9]+\.[0-9]+) ]]; then
      snapshot_openshift_version="${BASH_REMATCH[1]}"
    fi
  fi

  log "Writing cluster install snapshot role=${cluster_role} topology=${topology} cluster_id=${snapshot_cluster_id} to ${snapshot_dir}"

  local projected_co="${VALIDATION_SCRATCH}/${cluster_role}-snapshot-clusteroperators.json"
  local projected_nodes="${VALIDATION_SCRATCH}/${cluster_role}-snapshot-nodes.json"
  if ! jq '{
    items: [.items[] | {
      name: .metadata.name,
      available: (([.status.conditions[]? | select(.type=="Available") | .status] | first) // ""),
      degraded: (([.status.conditions[]? | select(.type=="Degraded") | .status] | first) // ""),
      progressing: (([.status.conditions[]? | select(.type=="Progressing") | .status] | first) // ""),
      version: ((.status.versions[]? | select(.name=="operator") | .version) // "")
    }]
  }' "${snapshot_co_json}" > "${projected_co}" 2>/dev/null; then
    if [[ "${overall_status}" == "INFO" ]]; then
      echo '{"items":[]}' > "${projected_co}"
    else
      error "Failed to project ClusterOperator JSON for ${cluster_role} snapshot"
      VALIDATION_FAILED=1
      return 1
    fi
  fi

  if ! jq '{
    items: [.items[] | {
      name: .metadata.name,
      ready: (([.status.conditions[]? | select(.type=="Ready") | .status] | first) // ""),
      schedulable: ((.spec.unschedulable // false) | not),
      roles: ([.metadata.labels | keys[] | select(startswith("node-role.kubernetes.io/"))] | map(sub("node-role.kubernetes.io/"; "")))
    }]
  }' "${snapshot_nodes_json}" > "${projected_nodes}" 2>/dev/null; then
    if [[ "${overall_status}" == "INFO" ]]; then
      echo '{"items":[]}' > "${projected_nodes}"
    else
      error "Failed to project node JSON for ${cluster_role} snapshot"
      VALIDATION_FAILED=1
      return 1
    fi
  fi

  if ! mv -- "${projected_co}" "${snapshot_dir}/clusteroperators.json" || \
     ! mv -- "${projected_nodes}" "${snapshot_dir}/nodes.json"; then
    if [[ "${overall_status}" != "INFO" ]]; then
      error "Failed to publish ${cluster_role} snapshot projections"
      VALIDATION_FAILED=1
    fi
    return 1
  fi

  local metadata_tmp="${VALIDATION_SCRATCH}/${cluster_role}-metadata.json"
  if ! jq -n \
    --arg topology "${topology}" \
    --arg cluster_role "${cluster_role}" \
    --arg openshift_version "${snapshot_openshift_version}" \
    --arg channel_group "${CHANNEL_GROUP:-}" \
    --arg cluster_id "${snapshot_cluster_id}" \
    --arg hosted_cluster_id "${CLUSTER_ID}" \
    --arg cluster_version "${cluster_version}" \
    --arg management_cluster_name "${mgmt_name}" \
    --arg management_cluster_id "${mgmt_id}" \
    --arg job_name "${JOB_NAME:-}" \
    --arg build_id "${BUILD_ID:-}" \
    --arg captured_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg overall_status "${overall_status}" \
    --argjson node_count "${node_count}" \
    --arg degraded_raw "${degraded_raw}" \
    --arg unavailable_raw "${unavailable_raw}" \
    --arg notready_raw "${notready_raw}" \
    --slurpfile operators "${snapshot_dir}/clusteroperators.json" \
    --slurpfile nodes "${snapshot_dir}/nodes.json" \
    '{
      topology: $topology,
      cluster_role: $cluster_role,
      openshift_version: $openshift_version,
      channel_group: $channel_group,
      cluster_id: $cluster_id,
      hosted_cluster_id: $hosted_cluster_id,
      cluster_version: $cluster_version,
      management_cluster_name: $management_cluster_name,
      management_cluster_id: $management_cluster_id,
      job_name: $job_name,
      build_id: $build_id,
      captured_at: $captured_at,
      overall_status: $overall_status,
      node_count: $node_count,
      degraded_operators: ($degraded_raw | split("\n") | map(select(length > 0))),
      unavailable_operators: ($unavailable_raw | split("\n") | map(select(length > 0))),
      notready_nodes: ($notready_raw | split("\n") | map(select(length > 0))),
      clusteroperator_count: (($operators[0].items // []) | length),
      ready_node_count: (($nodes[0].items // []) | map(select(.ready=="True")) | length)
    }' > "${metadata_tmp}" 2>/dev/null; then
    if [[ "${overall_status}" != "INFO" ]]; then
      error "Failed to write ${cluster_role} snapshot metadata"
      VALIDATION_FAILED=1
    fi
    return 1
  fi

  if ! mv -- "${metadata_tmp}" "${snapshot_dir}/metadata.json"; then
    if [[ "${overall_status}" != "INFO" ]]; then
      error "Failed to publish ${cluster_role} snapshot metadata"
      VALIDATION_FAILED=1
    fi
    return 1
  fi

  log "Cluster install snapshot JSON written (${cluster_role}): ${snapshot_dir}/metadata.json"
}

HOSTED_OVERALL="$( [[ ${VALIDATION_FAILED} -eq 1 ]] && echo FAILED || echo PASSED )"
primary_role="${topology}"
if [[ "${topology}" == "hcp" ]]; then
  primary_role="hosted"
fi
if ! write_install_snapshot "${primary_role}" "${ARTIFACT_DIR}" "${HOSTED_OVERALL}"; then
  VALIDATION_FAILED=1
  echo "Status: FAILED (unable to create a verified primary snapshot)" >> "${INSTALL_REPORT}"
fi

# Management-cluster capture is HCP-only. Classic and OSD GCP are
# single-cluster topologies and must keep writing only root ARTIFACT_DIR files. PASS/FAIL stays on this cluster.
if [[ "${topology}" == "hcp" ]]; then
  HOSTED_KUBECONFIG="${KUBECONFIG}"
  if resolve_management_kubeconfig; then
    if oc whoami --request-timeout=30s &>/dev/null; then
      collect_hcp_control_plane_diagnostics
      write_install_snapshot "management" "${ARTIFACT_DIR}/management" "INFO" || \
        log "WARNING: management-cluster install snapshot failed; hosted snapshot is still available"
    else
      log "WARNING: management kubeconfig is not usable; skipping management install snapshot"
    fi
  else
    log "WARNING: management kubeconfig not available; hosted/guest snapshot only"
  fi
  export KUBECONFIG="${HOSTED_KUBECONFIG}"
fi

###########################################
# Generate final validation report
###########################################
echo "" >> "${INSTALL_REPORT}"
echo "========================================" >> "${INSTALL_REPORT}"
echo "Validation Summary" >> "${INSTALL_REPORT}"
echo "========================================" >> "${INSTALL_REPORT}"

if [[ ${VALIDATION_FAILED} -eq 1 ]]; then
  echo "Overall Status: FAILED" >> "${INSTALL_REPORT}"
  error "Gap-analysis validation FAILED. See ${INSTALL_REPORT} for details."
else
  echo "Overall Status: PASSED" >> "${INSTALL_REPORT}"
  success "Gap-analysis validation PASSED."
fi

echo "Report generated at: ${INSTALL_REPORT}"
echo "Artifacts directory: ${ARTIFACT_DIR}"

log "Gap-analysis validation complete."
exit ${VALIDATION_FAILED}
