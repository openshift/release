#!/usr/bin/env bash
set +x
set -o errexit
set -o nounset
set -o pipefail

trap 'children=$(jobs -p); if [[ -n "${children}" ]]; then kill ${children} 2>/dev/null || true; wait ${children} 2>/dev/null || true; fi' TERM INT

STATE_FILE="${SHARED_DIR}/aro-hcp.env"
if [[ ! -s "${STATE_FILE}" ]]; then
  echo "Missing ${STATE_FILE}; provision must run first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${STATE_FILE}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-${AZURE_SUBSCRIPTION_ID:-}}"
: "${CLUSTER_NAME:?cluster name is required}"
: "${CUSTOMER_RG_NAME:?resource group is required}"
: "${SUBSCRIPTION_ID:?subscription is required}"

CLUSTER_CONFIG_FILE="${SHARED_DIR}/cluster-config"
KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

# Convert a CI duration value into seconds for the readiness deadline.
duration_to_seconds() {
  local value="$1"
  case "${value}" in
    *s) echo "${value%s}" ;;
    *m) echo $(( ${value%m} * 60 )) ;;
    *h) echo $(( ${value%h} * 3600 )) ;;
    ''|*[!0-9]*) echo "Unsupported duration: ${value}" >&2; return 1 ;;
    *) echo "${value}" ;;
  esac
}

# Create valid shared metadata before recording readiness results.
ensure_metadata() {
  if [[ ! -s "${CLUSTER_CONFIG_FILE}" ]] || ! jq empty "${CLUSTER_CONFIG_FILE}" >/dev/null 2>&1; then
    jq -n '{provider: "azure", cluster: {}, timers: {}, nodepools: {}}' > "${CLUSTER_CONFIG_FILE}.tmp"
    mv "${CLUSTER_CONFIG_FILE}.tmp" "${CLUSTER_CONFIG_FILE}"
    chmod 600 "${CLUSTER_CONFIG_FILE}"
  fi
}

# Record a numeric cluster-level readiness timer.
record_timer() {
  local key="$1" value="$2" tmp
  ensure_metadata
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg key "${key}" --argjson value "${value}" '.timers[$key] = $value' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Record a string-valued cluster-level readiness field.
record_timer_string() {
  local key="$1" value="$2" tmp
  ensure_metadata
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg key "${key}" --arg value "${value}" '.timers[$key] = $value' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Record a numeric control-plane install-state timer.
record_install_timer() {
  local key="$1" value="$2" tmp
  ensure_metadata
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg key "${key}" --argjson value "${value}" '.timers.install[$key] = $value' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Keep the install-state keys compatible with the ROSA metadata document.
ensure_install_timers() {
  local tmp
  ensure_metadata
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq '.timers.install = ({claim: 0, waiting: 0, validating: 0, pending: 0, installing: 0} + (.timers.install // {}))' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Record a numeric readiness timer for one node pool.
record_nodepool_timer() {
  local nodepool="$1" key="$2" value="$3" tmp
  ensure_metadata
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg nodepool "${nodepool}" --arg key "${key}" --argjson value "${value}" \
    '.nodepools[$nodepool][$key] = $value' "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

export AZURE_CONFIG_DIR="${SHARED_DIR}/azure-config-ready"
mkdir -p "${AZURE_CONFIG_DIR}"
umask 077
SP_FILE="${CLUSTER_PROFILE_DIR}/osServicePrincipalHcp.json"
if [[ ! -s "${SP_FILE}" ]]; then
  echo "${SP_FILE} is missing; cannot authenticate readiness checks." >&2
  exit 1
fi
AZURE_CLIENT_ID=$(jq -er '.clientId' "${SP_FILE}")
AZURE_CLIENT_SECRET=$(jq -er '.clientSecret' "${SP_FILE}")
AZURE_TENANT_ID=$(jq -er '.tenantId' "${SP_FILE}")
set +x
az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" --only-show-errors --output none
unset AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID
az account set --subscription "${SUBSCRIPTION_ID}"
az extension add --name aro --upgrade --yes --only-show-errors
az aro hcp -h >/dev/null

timeout_seconds=$(duration_to_seconds "${READY_WAIT_TIMEOUT}")
deadline=$((SECONDS + timeout_seconds))
nodes_ready_start=$(date +%s)
rp_cluster_ready=false
rp_nodepools_ready=false
guest_api_ready=false
cluster_version_ready=false
cluster_operators_ready=false
guest_pods_ready=false
worker_nodes_ready=false

# Check the hosted control-plane RP state and record its completion timer.
check_rp_cluster() {
  local state now start
  state=$(az aro hcp cluster show --name "${CLUSTER_NAME}" --resource-group "${CUSTOMER_RG_NAME}" \
    --query properties.provisioningState --output tsv 2>/dev/null || true)
  echo "HCP ${CLUSTER_NAME} provisioningState=${state:-NotFound}"
  case "${state}" in
    Succeeded)
      rp_cluster_ready=true
      if [[ "$(jq -r '.timers.control_plane_ready // empty' "${CLUSTER_CONFIG_FILE}" 2>/dev/null || true)" == "" ]]; then
        now=$(date +%s)
        record_timer control_plane_ready "${now}"
        start=$(jq -r '.timers.control_plane_install_start // .timers.global_start // empty' "${CLUSTER_CONFIG_FILE}")
        [[ "${start}" =~ ^[0-9]+$ ]] && record_timer control_plane_install_seconds "$((now - start))"
      fi
      return 0
      ;;
    Failed|Canceled|Cancelled|Error)
      echo "HCP ${CLUSTER_NAME} failed with provisioningState=${state}." >&2
      return 2
      ;;
  esac
  return 1
}

# Check that every Azure RP node-pool operation has succeeded.
check_rp_nodepools() {
  local json bad pending name now start
  json=$(az aro hcp cluster nodepool list --cluster-name "${CLUSTER_NAME}" \
    --resource-group "${CUSTOMER_RG_NAME}" --output json 2>/dev/null || true)
  if [[ -z "${json}" ]] || ! jq -e 'type == "array"' <<<"${json}" >/dev/null 2>&1; then
    echo "Waiting for ARO HCP node pools to appear."
    return 1
  fi
  if [[ "${EXPECTED_WORKER_NODES:-}" == "0" ]] && [[ "$(jq 'length' <<<"${json}")" == "0" ]]; then
    rp_nodepools_ready=true
    return 0
  fi
  if [[ "$(jq 'length' <<<"${json}")" == "0" ]]; then
    echo "Waiting for ARO HCP node pools to appear."
    return 1
  fi
  bad=$(jq -r '.[] | select((.properties.provisioningState // .provisioningState // "") | IN("Failed", "Canceled", "Cancelled", "Error")) | (.name // "unknown") + ":" + (.properties.provisioningState // .provisioningState)' <<<"${json}")
  if [[ -n "${bad}" ]]; then
    echo "Node-pool failure detected: ${bad}" >&2
    return 2
  fi
  pending=$(jq '[.[] | select((.properties.provisioningState // .provisioningState // "") != "Succeeded")] | length' <<<"${json}")
  if (( pending > 0 )); then
    echo "Waiting for ${pending} node-pool operation(s) to reach Succeeded."
    return 1
  fi
  rp_nodepools_ready=true
  while IFS=$'\t' read -r name; do
    [[ -z "${name}" ]] && continue
    if [[ "$(jq -r --arg name "${name}" '.nodepools[$name].rp_ready // empty' "${CLUSTER_CONFIG_FILE}" 2>/dev/null || true)" == "" ]]; then
      now=$(date +%s)
      record_nodepool_timer "${name}" rp_ready "${now}"
      start=$(jq -r --arg name "${name}" '.nodepools[$name].install_start // .timers.global_start // empty' "${CLUSTER_CONFIG_FILE}")
      [[ "${start}" =~ ^[0-9]+$ ]] && record_nodepool_timer "${name}" install_seconds "$((now - start))"
    fi
  done < <(jq -r '.[].name // empty' <<<"${json}")
  return 0
}

# Check that the guest API can be reached with the downloaded kubeconfig.
check_guest_api() {
  [[ -s "${KUBECONFIG_FILE}" ]] || { echo "Waiting for guest kubeconfig."; return 1; }
  if KUBECONFIG="${KUBECONFIG_FILE}" oc whoami >/dev/null 2>&1; then
    guest_api_ready=true
    return 0
  fi
  echo "Guest API is not reachable yet."
  return 1
}

# Check that ClusterVersion is available, stable, and not degraded.
check_cluster_version() {
  local json available progressing degraded
  json=$(KUBECONFIG="${KUBECONFIG_FILE}" oc get clusterversion version -o json 2>/dev/null || true)
  [[ -n "${json}" ]] || { echo "Waiting for ClusterVersion."; return 1; }
  available=$(jq -r '.status.conditions[]? | select(.type == "Available") | .status' <<<"${json}" | head -1)
  progressing=$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .status' <<<"${json}" | head -1)
  degraded=$(jq -r '.status.conditions[]? | select(.type == "Degraded") | .status' <<<"${json}" | head -1)
  echo "ClusterVersion Available=${available:-Unknown} Progressing=${progressing:-Unknown} Degraded=${degraded:-Unknown}"
  if [[ "${available}" == "True" && "${progressing}" == "False" && "${degraded}" == "False" ]]; then
    cluster_version_ready=true
    return 0
  fi
  return 1
}

# Check that all guest cluster operators are available and healthy.
check_cluster_operators() {
  local json bad
  json=$(KUBECONFIG="${KUBECONFIG_FILE}" oc get clusteroperators -o json 2>/dev/null || true)
  [[ -n "${json}" ]] || { echo "Waiting for ClusterOperators."; return 1; }
  bad=$(jq -r '.items[] |
    select((any(.status.conditions[]?; .type == "Available" and .status == "True") | not) or
           any(.status.conditions[]?; .type == "Progressing" and .status == "True") or
           any(.status.conditions[]?; .type == "Degraded" and .status == "True")) |
    .metadata.name' <<<"${json}")
  if [[ -n "${bad}" ]]; then
    echo "ClusterOperators not ready: $(tr '\n' ' ' <<<"${bad}")"
    return 1
  fi
  cluster_operators_ready=true
  return 0
}

# Check that non-terminal guest workloads are running or completed.
check_guest_pods() {
  local json bad
  json=$(KUBECONFIG="${KUBECONFIG_FILE}" oc get pods --all-namespaces -o json 2>/dev/null || true)
  [[ -n "${json}" ]] || { echo "Waiting for guest pods."; return 1; }
  # Job-owned pods may remain Failed after the Job has completed. They are
  # terminal workload artifacts and should not block cluster readiness.
  bad=$(jq -r '.items[] |
    (.status.phase // "Unknown") as $phase |
    (any(.metadata.ownerReferences[]?; .kind == "Job")) as $job_owned |
    select($phase != "Running" and
           $phase != "Succeeded" and
           (($job_owned and $phase == "Failed") | not)) |
    [.metadata.namespace, .metadata.name, $phase] | @tsv' <<<"${json}")
  if [[ -n "${bad}" ]]; then
    echo "Guest pods not ready: $(head -5 <<<"${bad}" | tr '\n' '; ')"
    return 1
  fi
  guest_pods_ready=true
  return 0
}

# Check that the expected worker nodes are Ready and schedulable.
check_worker_nodes() {
  local nodes desired ready
  nodes=$(KUBECONFIG="${KUBECONFIG_FILE}" oc get nodes -o json 2>/dev/null || true)
  [[ -n "${nodes}" ]] || { echo "Waiting for guest nodes."; return 1; }
  desired="${EXPECTED_WORKER_NODES:-}"
  if [[ -z "${desired}" ]]; then
    desired=$(az aro hcp cluster nodepool list --cluster-name "${CLUSTER_NAME}" \
      --resource-group "${CUSTOMER_RG_NAME}" --query '[].properties.replicas' --output tsv 2>/dev/null \
      | awk '{sum += $1} END {print sum + 0}')
  fi
  if [[ "${desired}" == "0" ]]; then
    worker_nodes_ready=true
    echo "No worker nodes requested; worker-node readiness is complete."
    return 0
  fi
  ready=$(jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/worker"] != null) | select(.spec.unschedulable != true) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"${nodes}")
  echo "Schedulable Ready workers=${ready}/${desired}"
  if [[ "${desired}" =~ ^[0-9]+$ ]] && (( desired > 0 && ready >= desired )); then
    worker_nodes_ready=true
    return 0
  fi
  return 1
}

echo "Waiting for ARO HCP ${CLUSTER_NAME} and all guest resources to become ready."
while (( SECONDS < deadline )); do
  rc=0
  if check_rp_cluster; then :; else rc=$?; fi
  [[ "${rc}" -ne 2 ]] || exit 1
  rc=0
  if check_rp_nodepools; then :; else rc=$?; fi
  [[ "${rc}" -ne 2 ]] || exit 1
  check_guest_api || true
  if [[ "${guest_api_ready}" == true ]]; then
    if [[ "${SKIP_CLUSTER_VERSION_CHECK}" == "true" ]]; then
      echo "Skipping ClusterVersion readiness check by configuration."
      cluster_version_ready=true
    else
      check_cluster_version || true
    fi
    check_cluster_operators || true
    check_guest_pods || true
    check_worker_nodes || true
  fi
  if [[ "${rp_cluster_ready}" == true && "${rp_nodepools_ready}" == true && \
        "${guest_api_ready}" == true && "${cluster_version_ready}" == true && \
        "${cluster_operators_ready}" == true && "${guest_pods_ready}" == true && \
        "${worker_nodes_ready}" == true ]]; then
    now=$(date +%s)
    record_timer guest_ready "${now}"
    record_timer global_end "${now}"
    global_start=$(jq -r '.timers.global_start // empty' "${CLUSTER_CONFIG_FILE}")
    control_plane_start=$(jq -r '.timers.control_plane_install_start // .timers.global_start // empty' "${CLUSTER_CONFIG_FILE}")
    control_plane_ready_at=$(jq -r '.timers.control_plane_ready // empty' "${CLUSTER_CONFIG_FILE}")
    control_plane_ready_seconds=0
    if [[ "${control_plane_start}" =~ ^[0-9]+$ ]]; then
      if [[ "${control_plane_ready_at}" =~ ^[0-9]+$ ]]; then
        control_plane_ready_seconds=$((control_plane_ready_at - control_plane_start))
      else
        control_plane_ready_seconds=$((now - control_plane_start))
      fi
      record_timer control_plane_install_seconds "${control_plane_ready_seconds}"
    fi
    if [[ "${global_start}" =~ ^[0-9]+$ ]]; then
      record_timer cluster_ready_seconds "$((now - global_start))"
      record_timer total_install_time "$((now - global_start))"
      # ROSA's common cluster_ready/install_ready timers represent control-plane
      # readiness; retain the full guest readiness duration separately.
      record_timer cluster_ready "${control_plane_ready_seconds}"
    fi
    while IFS=$'\t' read -r name start; do
      [[ -z "${name}" ]] && continue
      [[ "${start}" =~ ^[0-9]+$ ]] || start="${global_start}"
      record_nodepool_timer "${name}" guest_ready "${now}"
      record_nodepool_timer "${name}" ready_seconds "$((now - start))"
    done < <(jq -r '.nodepools | to_entries[] | [.key, (.value.install_start // empty)] | @tsv' "${CLUSTER_CONFIG_FILE}")
    workers_ready_seconds=0
    if [[ -s "${SHARED_DIR}/aro-hcp-worker-nodepools" ]]; then
      while IFS= read -r worker_nodepool; do
        [[ -n "${worker_nodepool}" ]] || continue
        worker_ready=$(jq -r --arg name "${worker_nodepool}" '.nodepools[$name].ready_seconds // empty' "${CLUSTER_CONFIG_FILE}")
        if [[ "${worker_ready}" =~ ^[0-9]+$ ]] && (( worker_ready > workers_ready_seconds )); then
          workers_ready_seconds="${worker_ready}"
        fi
      done < "${SHARED_DIR}/aro-hcp-worker-nodepools"
    else
      worker_ready=$(jq -r '.nodepools.workers.ready_seconds // empty' "${CLUSTER_CONFIG_FILE}")
      [[ "${worker_ready}" =~ ^[0-9]+$ ]] && workers_ready_seconds="${worker_ready}"
    fi
    (( workers_ready_seconds > 0 )) && record_timer nodepool_ready_seconds "${workers_ready_seconds}"
    record_timer nodes_ready "$((now - nodes_ready_start))"
    ensure_install_timers
    install_state_total=$(jq '[.timers.install // {} | to_entries[] | select(.key | IN("claim", "waiting", "validating", "pending", "installing")) | (.value | tonumber? // 0)] | add // 0' "${CLUSTER_CONFIG_FILE}")
    if [[ "${install_state_total}" == "0" && "${control_plane_ready_seconds}" -gt 0 ]]; then
      record_install_timer installing "${control_plane_ready_seconds}"
    fi
    record_timer install_ready "${control_plane_ready_seconds}"
    record_timer_string status ready
    mkdir -p "${ARTIFACT_DIR:-${SHARED_DIR}}"
    cp "${CLUSTER_CONFIG_FILE}" "${ARTIFACT_DIR:-${SHARED_DIR}}/cluster-config"
    echo "All ARO HCP readiness checks passed."
    jq '.timers, .nodepools' "${CLUSTER_CONFIG_FILE}"
    exit 0
  fi
  sleep 30
done

echo "Timed out waiting for ARO HCP ${CLUSTER_NAME} readiness." >&2
jq '{timers: .timers, nodepools: .nodepools}' "${CLUSTER_CONFIG_FILE}" >&2 || true
exit 1
