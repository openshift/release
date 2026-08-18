#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# --- Collect cluster IDs from shared dir ---
CLUSTER_IDS=()

# Read single cluster-id file
single_id=$(cat "${SHARED_DIR}/cluster-id" 2>/dev/null || echo "")
if [[ -n "${single_id}" ]]; then
  CLUSTER_IDS+=("${single_id}")
fi

# Read multi cluster-ids file (one per line)
if [[ -f "${SHARED_DIR}/cluster-ids" ]]; then
  while IFS= read -r line; do
    line=$(echo "${line}" | xargs)  # trim whitespace
    if [[ -n "${line}" ]]; then
      # Avoid duplicates
      duplicate=false
      for existing in "${CLUSTER_IDS[@]+"${CLUSTER_IDS[@]}"}"; do
        if [[ "${existing}" == "${line}" ]]; then
          duplicate=true
          break
        fi
      done
      if [[ "${duplicate}" == "false" ]]; then
        CLUSTER_IDS+=("${line}")
      fi
    fi
  done < "${SHARED_DIR}/cluster-ids"
fi

NO_CLUSTER_ID=false
if [[ ${#CLUSTER_IDS[@]} -eq 0 ]]; then
  NO_CLUSTER_ID=true
fi

# --- Determine logging mode ---
if [[ "${NO_CLUSTER_ID}" == "true" ]]; then
  echo "No cluster-id found -- collecting all CS logs for time window (fallback mode)"
elif [[ ${#CLUSTER_IDS[@]} -eq 1 ]]; then
  echo "Collecting RHOBS logs for cluster ${CLUSTER_IDS[0]}"
else
  echo "Collecting RHOBS logs for ${#CLUSTER_IDS[@]} clusters"
fi

RHOBS_LOG_BASE="${ARTIFACT_DIR}/rhobs-logs"
mkdir -p "${RHOBS_LOG_BASE}"

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
OCM_LOGGED_IN=false
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}" && OCM_LOGGED_IN=true || \
    echo "WARNING: OCM login failed, MC-side logs will be skipped"
elif [[ -n "${OCM_TOKEN}" ]]; then
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}" && OCM_LOGGED_IN=true || \
    echo "WARNING: OCM login failed, MC-side logs will be skipped"
else
  echo "No OCM credentials found, MC-side logs will be skipped"
fi

HIVE_OCM_URL="${RHOBS_HIVE_OCM_URL:-staging}"
SINCE="${RHOBS_LOG_SINCE:-3h}"

echo ""
echo "=== RHOBS Log Collection ==="
echo "Mode: $(if [[ "${NO_CLUSTER_ID}" == "true" ]]; then echo "fallback (no cluster-id)"; elif [[ ${#CLUSTER_IDS[@]} -eq 1 ]]; then echo "single cluster"; else echo "multi-cluster (${#CLUSTER_IDS[@]})"; fi)"
echo "Cluster IDs: ${CLUSTER_IDS[*]+"${CLUSTER_IDS[*]}":-none}"
echo ""

collect_logs() {
  local label="$1"
  local output="$2"
  local output_dir="$3"
  shift 3
  mkdir -p "${output_dir}"
  echo "Collecting ${label}..."
  osdctl rhobs logs "$@" 2>&1 | grep -v "^time=\|^Vault" > "${output_dir}/${output}" || true
}

# --- Per-cluster collection function (MC-side + CS provisioning) ---
collect_for_cluster() {
  local CLUSTER_ID="$1"
  local RHOBS_LOG_DIR="$2"
  mkdir -p "${RHOBS_LOG_DIR}"

  echo ""
  echo "--- Collecting logs for cluster ${CLUSTER_ID} ---"

  # Resolve MC cluster ID
  local MC_CLUSTER_ID=""
  local MC_NAME=""
  if [[ "${OCM_LOGGED_IN}" == "true" ]]; then
    if [[ -f "${SHARED_DIR}/mc-cluster-name" ]]; then
      MC_NAME=$(cat "${SHARED_DIR}/mc-cluster-name")
      MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id' 2>/dev/null || echo "")
    else
      MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/provision_shard 2>/dev/null | jq -r .management_cluster || echo "")
      if [[ -n "${MC_NAME}" && "${MC_NAME}" != "null" ]]; then
        MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id' 2>/dev/null || echo "")
      fi
    fi
  fi

  echo "  MC: ${MC_NAME:-unknown} (${MC_CLUSTER_ID:-unknown})"

  if [[ -n "${MC_CLUSTER_ID}" && "${MC_CLUSTER_ID}" != "null" ]]; then

    # 1. HCP guest cluster logs (etcd, kube-apiserver, etc.) from the sub-namespace
    collect_logs "HCP guest cluster logs" "hcp-guest-cluster.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      --query "{k8s_namespace_name=~\"ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-.*\"}" \
      --since "${SINCE}" --limit 50000 --direction forward -o text

    # 2. HyperShift operator logs filtered for this cluster
    collect_logs "HyperShift operator logs (this cluster)" "hypershift-operator.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      -n "hypershift" --contain "${CLUSTER_ID}" \
      --since "${SINCE}" --limit 10000 --direction forward -o text

    # 3. HyperShift operator (all logs, for broader context)
    collect_logs "HyperShift operator logs (all)" "hypershift-operator-all.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      -n "hypershift" \
      --since "${SINCE}" --limit 10000 --direction forward -o text

    # 4. MCO logs (ClusterImagePolicy rollout)
    collect_logs "MCO logs" "mco.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      -n "openshift-machine-config-operator" \
      --since "${SINCE}" --limit 5000 --direction forward -o text

    # 5. ACM logs
    collect_logs "ACM logs" "acm.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      -n "open-cluster-management" \
      --since "${SINCE}" --limit 5000 --direction forward -o text

    # 6. cert-manager logs
    collect_logs "cert-manager logs" "cert-manager.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      -n "cert-manager" \
      --since "${SINCE}" --limit 5000 --direction forward -o text

    # 7. RMO (Route Monitor Operator) logs
    collect_logs "RMO logs" "rmo-logs.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      -n "openshift-route-monitor-operator" \
      --since "${SINCE}" --limit 5000 --direction forward -o text

    # 8. AVO (AWS VPCE Operator) logs
    collect_logs "AVO logs" "avo-logs.log" "${RHOBS_LOG_DIR}" \
      -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
      -n "openshift-aws-vpce-operator" \
      --since "${SINCE}" --limit 5000 --direction forward -o text
  fi
}

# --- MC-side log collection ---
if [[ "${NO_CLUSTER_ID}" == "true" ]]; then
  echo "Skipping MC-side logs -- no cluster-id available"
elif [[ ${#CLUSTER_IDS[@]} -eq 1 ]]; then
  # Single cluster: logs go directly under rhobs-logs/
  collect_for_cluster "${CLUSTER_IDS[0]}" "${RHOBS_LOG_BASE}"
else
  # Multiple clusters: logs go under rhobs-logs/<cluster-id>/
  for cid in "${CLUSTER_IDS[@]}"; do
    collect_for_cluster "${cid}" "${RHOBS_LOG_BASE}/${cid}"
  done
fi

# 9. CS provisioning logs via RHOBS Loki API (global cell)
if [[ -f /usr/local/rhobs-oidc/client_id ]]; then
  echo ""
  echo "Collecting CS provisioning logs from RHOBS..."

  OIDC_CLIENT_ID=$(cat /usr/local/rhobs-oidc/client_id)
  OIDC_CLIENT_SECRET=$(cat /usr/local/rhobs-oidc/client_secret)
  OIDC_ISSUER=$(cat /usr/local/rhobs-oidc/oidc_issuer_url 2>/dev/null || echo "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token")

  case "${OCM_LOGIN_ENV}" in
    staging)  LOKI_BASE="https://us-east-1-0.rhobs.api.stage.openshift.com/api/logs/v1/hcp/loki/api/v1"; CS_NS="uhc-stage" ;;
    production) LOKI_BASE="https://us-east-1-0.rhobs.api.openshift.com/api/logs/v1/hcp/loki/api/v1"; CS_NS="uhc-production" ;;
    integration) LOKI_BASE="https://us-west-2-0.rhobs.api.integration.openshift.com/api/logs/v1/hcp/loki/api/v1"; CS_NS="uhc-integration" ;;
    *) CS_NS="" ;;
  esac

  if [[ -n "${CS_NS}" ]]; then
    TOKEN=$(curl -sf -X POST "$OIDC_ISSUER" \
      -d "grant_type=client_credentials" \
      -d "client_id=$OIDC_CLIENT_ID" \
      -d "client_secret=$OIDC_CLIENT_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

    if [[ -n "${TOKEN}" ]]; then
      # Parse SINCE duration (supports h and m suffixes)
      since_seconds=10800
      if [[ "${SINCE}" =~ ^([0-9]+)h$ ]]; then
        since_seconds=$(( BASH_REMATCH[1] * 3600 ))
      elif [[ "${SINCE}" =~ ^([0-9]+)m$ ]]; then
        since_seconds=$(( BASH_REMATCH[1] * 60 ))
      fi
      START_NS=$(( ($(date +%s) - since_seconds) * 1000000000 ))
      END_NS=$(( $(date +%s) * 1000000000 ))

      # Helper: query Loki and extract log lines
      query_loki() {
        local query="$1"
        local output_file="$2"
        local limit="${3:-10000}"
        curl -sf --max-time 120 \
          -H "Authorization: Bearer $TOKEN" \
          --data-urlencode "query=${query}" \
          --data-urlencode "start=${START_NS}" \
          --data-urlencode "end=${END_NS}" \
          --data-urlencode "limit=${limit}" \
          --data-urlencode "direction=forward" \
          -G "$LOKI_BASE/query_range" 2>/dev/null | \
          python3 -c "
import sys, json
d = json.load(sys.stdin)
for stream in d.get('data',{}).get('result',[]):
    for ts_ns, msg in stream.get('values',[]):
        print(msg)
" > "${output_file}" 2>/dev/null || true
      }

      if [[ "${NO_CLUSTER_ID}" == "true" ]]; then
        # Fallback mode: collect ALL CS provisioning logs (no cluster filter)
        CS_LOG_DIR="${RHOBS_LOG_BASE}/all-cs"
        mkdir -p "${CS_LOG_DIR}"
        echo "  Querying CS provisioning logs for entire namespace (no cluster-id filter)..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"}" "${CS_LOG_DIR}/cs-provisioning.log"

        # CS telemetry events (ROSA HCP lifecycle tags) -- already generic
        echo "  Querying CS telemetry events..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"[ROSA HCP -\"" "${CS_LOG_DIR}/cs-telemetry.log" 5000

      elif [[ ${#CLUSTER_IDS[@]} -eq 1 ]]; then
        # Single cluster: CS logs go in base directory
        echo "  Querying CS provisioning logs for cluster ${CLUSTER_IDS[0]}..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"${CLUSTER_IDS[0]}\"" "${RHOBS_LOG_BASE}/cs-provisioning.log"

        # CS telemetry events
        echo "  Querying CS telemetry events..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"[ROSA HCP -\"" "${RHOBS_LOG_BASE}/cs-telemetry.log" 5000

      else
        # Multiple clusters: per-cluster CS logs
        for cid in "${CLUSTER_IDS[@]}"; do
          local_dir="${RHOBS_LOG_BASE}/${cid}"
          mkdir -p "${local_dir}"
          echo "  Querying CS provisioning logs for cluster ${cid}..."
          query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"${cid}\"" "${local_dir}/cs-provisioning.log"
        done

        # CS telemetry events (generic, shared across all clusters)
        echo "  Querying CS telemetry events..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"[ROSA HCP -\"" "${RHOBS_LOG_BASE}/cs-telemetry.log" 5000
      fi
    else
      echo "WARNING: Failed to get RHOBS OIDC token, skipping CS logs"
    fi
  fi
else
  echo "No RHOBS OIDC credentials found, skipping CS provisioning logs"
fi

# Summary
echo ""
echo "=== RHOBS Log Collection Summary ==="
find "${RHOBS_LOG_BASE}" -name "*.log" -type f | sort | while read -r f; do
  rel_path="${f#"${RHOBS_LOG_BASE}/"}"
  lines=$(wc -l < "$f" 2>/dev/null || echo "0")
  size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
  echo "  ${rel_path}: ${lines} lines (${size})"
done
