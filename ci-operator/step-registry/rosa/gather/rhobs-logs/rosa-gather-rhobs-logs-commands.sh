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

SINCE="${RHOBS_LOG_SINCE:-3h}"

echo ""
echo "=== RHOBS Log Collection ==="
echo "Mode: $(if [[ "${NO_CLUSTER_ID}" == "true" ]]; then echo "fallback (no cluster-id)"; elif [[ ${#CLUSTER_IDS[@]} -eq 1 ]]; then echo "single cluster"; else echo "multi-cluster (${#CLUSTER_IDS[@]})"; fi)"
echo "Cluster IDs: ${CLUSTER_IDS[*]+"${CLUSTER_IDS[*]}":-none}"
echo ""

# --- All log collection via RHOBS Loki API ---
if [[ -f /usr/local/rhobs-oidc/client_id ]]; then
  echo "Collecting logs from RHOBS Loki API..."

  OIDC_CLIENT_ID=$(cat /usr/local/rhobs-oidc/client_id)
  OIDC_CLIENT_SECRET=$(cat /usr/local/rhobs-oidc/client_secret)
  OIDC_ISSUER=$(cat /usr/local/rhobs-oidc/oidc_issuer_url 2>/dev/null || echo "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token")

  case "${OCM_LOGIN_ENV}" in
    staging)     LOKI_BASE="https://us-east-1-0.rhobs.api.stage.openshift.com/api/logs/v1/hcp/loki/api/v1"; CS_NS="uhc-stage" ;;
    production)  LOKI_BASE="https://us-east-1-0.rhobs.api.openshift.com/api/logs/v1/hcp/loki/api/v1"; CS_NS="uhc-production" ;;
    integration) LOKI_BASE="https://us-west-2-0.rhobs.api.integration.openshift.com/api/logs/v1/hcp/loki/api/v1"; CS_NS="uhc-integration" ;;
    *)
      echo "WARNING: Unsupported OCM_LOGIN_ENV '${OCM_LOGIN_ENV}' for RHOBS log collection -- skipping"
      echo "  Supported values: staging, production, integration"
      LOKI_BASE=""
      CS_NS=""
      ;;
  esac

  if [[ -n "${LOKI_BASE}" && -n "${CS_NS}" ]]; then
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
        echo "    Loki query: ${query} (limit=${limit})"
        curl -sf --max-time 120 \
          -H "Authorization: Bearer $TOKEN" \
          --data-urlencode "query=${query}" \
          --data-urlencode "start=${START_NS}" \
          --data-urlencode "end=${END_NS}" \
          --data-urlencode "limit=${limit}" \
          --data-urlencode "direction=forward" \
          -G "$LOKI_BASE/query_range" | \
          python3 -c "
import sys, json
d = json.load(sys.stdin)
for stream in d.get('data',{}).get('result',[]):
    for ts_ns, msg in stream.get('values',[]):
        print(msg)
" > "${output_file}" 2>/dev/null || true
      }

      # --- MC-side log collection via Loki ---
      collect_mc_logs_for_cluster() {
        local CLUSTER_ID="$1"
        local RHOBS_LOG_DIR="$2"
        mkdir -p "${RHOBS_LOG_DIR}"

        echo ""
        echo "--- Collecting MC-side logs for cluster ${CLUSTER_ID} ---"

        # 1. HCP guest cluster logs (etcd, kube-apiserver, etc.)
        echo "  Collecting HCP guest cluster logs..."
        query_loki "{k8s_namespace_name=~\"ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-.*\"}" \
          "${RHOBS_LOG_DIR}/hcp-guest-cluster.txt" 50000

        # 2. HyperShift operator logs filtered for this cluster
        echo "  Collecting HyperShift operator logs (this cluster)..."
        query_loki "{k8s_namespace_name=\"hypershift\"} |= \"${CLUSTER_ID}\"" \
          "${RHOBS_LOG_DIR}/hypershift-operator.txt" 10000

        # 3. HyperShift operator (all logs)
        echo "  Collecting HyperShift operator logs (all)..."
        query_loki "{k8s_namespace_name=\"hypershift\"}" \
          "${RHOBS_LOG_DIR}/hypershift-operator-all.txt" 10000

        # 4. MCO logs
        echo "  Collecting MCO logs..."
        query_loki "{k8s_namespace_name=\"openshift-machine-config-operator\"}" \
          "${RHOBS_LOG_DIR}/mco.txt" 5000

        # 5. ACM logs
        echo "  Collecting ACM logs..."
        query_loki "{k8s_namespace_name=\"open-cluster-management-agent-addon\"}" \
          "${RHOBS_LOG_DIR}/acm.txt" 5000

        # 6. cert-manager logs
        echo "  Collecting cert-manager logs..."
        query_loki "{k8s_namespace_name=\"cert-manager\"}" \
          "${RHOBS_LOG_DIR}/cert-manager.txt" 5000

        # 7. Route Monitor Operator logs
        echo "  Collecting Route Monitor Operator logs..."
        query_loki "{k8s_namespace_name=\"openshift-route-monitor-operator\"}" \
          "${RHOBS_LOG_DIR}/route-monitor-operator-logs.txt" 5000

        # 8. AWS VPCE Operator logs
        echo "  Collecting AWS VPCE Operator logs..."
        query_loki "{k8s_namespace_name=\"openshift-aws-vpce-operator\"}" \
          "${RHOBS_LOG_DIR}/aws-vpce-operator-logs.txt" 5000
      }

      if [[ "${NO_CLUSTER_ID}" == "true" ]]; then
        # Collect MC-side logs that only need a namespace (no cluster-id required)
        echo ""
        echo "--- Collecting MC-side logs (namespace-only, no cluster-id filter) ---"
        echo "  Skipping HCP guest cluster and filtered HyperShift logs (require cluster-id)"

        echo "  Collecting HyperShift operator logs (all)..."
        query_loki "{k8s_namespace_name=\"hypershift\"}" \
          "${RHOBS_LOG_BASE}/hypershift-operator-all.txt" 10000

        echo "  Collecting MCO logs..."
        query_loki "{k8s_namespace_name=\"openshift-machine-config-operator\"}" \
          "${RHOBS_LOG_BASE}/mco.txt" 5000

        echo "  Collecting ACM logs..."
        query_loki "{k8s_namespace_name=\"open-cluster-management-agent-addon\"}" \
          "${RHOBS_LOG_BASE}/acm.txt" 5000

        echo "  Collecting cert-manager logs..."
        query_loki "{k8s_namespace_name=\"cert-manager\"}" \
          "${RHOBS_LOG_BASE}/cert-manager.txt" 5000

        echo "  Collecting Route Monitor Operator logs..."
        query_loki "{k8s_namespace_name=\"openshift-route-monitor-operator\"}" \
          "${RHOBS_LOG_BASE}/route-monitor-operator-logs.txt" 5000

        echo "  Collecting AWS VPCE Operator logs..."
        query_loki "{k8s_namespace_name=\"openshift-aws-vpce-operator\"}" \
          "${RHOBS_LOG_BASE}/aws-vpce-operator-logs.txt" 5000

      elif [[ ${#CLUSTER_IDS[@]} -eq 1 ]]; then
        # Single cluster: logs go directly under rhobs-logs/
        collect_mc_logs_for_cluster "${CLUSTER_IDS[0]}" "${RHOBS_LOG_BASE}"
      else
        # Multiple clusters: logs go under rhobs-logs/<cluster-id>/
        for cid in "${CLUSTER_IDS[@]}"; do
          collect_mc_logs_for_cluster "${cid}" "${RHOBS_LOG_BASE}/${cid}"
        done
      fi

      # --- CS provisioning logs ---
      echo ""
      echo "--- Collecting CS provisioning logs ---"

      if [[ "${NO_CLUSTER_ID}" == "true" ]]; then
        # Fallback mode: collect ALL CS provisioning logs (no cluster filter)
        CS_LOG_DIR="${RHOBS_LOG_BASE}/all-cs"
        mkdir -p "${CS_LOG_DIR}"
        echo "  Querying CS provisioning logs for entire namespace (no cluster-id filter)..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |!= \"[ROSA HCP -\"" "${CS_LOG_DIR}/cs-provisioning.txt"

        # CS telemetry events (ROSA HCP lifecycle tags) -- already generic
        echo "  Querying CS telemetry events..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"[ROSA HCP -\"" "${CS_LOG_DIR}/cs-telemetry.txt" 5000

      elif [[ ${#CLUSTER_IDS[@]} -eq 1 ]]; then
        # Single cluster: CS logs go in base directory
        echo "  Querying CS provisioning logs for cluster ${CLUSTER_IDS[0]}..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"${CLUSTER_IDS[0]}\" |!= \"[ROSA HCP -\"" \
          "${RHOBS_LOG_BASE}/cs-provisioning.txt"

        # CS telemetry events
        echo "  Querying CS telemetry events..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"[ROSA HCP -\"" \
          "${RHOBS_LOG_BASE}/cs-telemetry.txt" 5000

      else
        # Multiple clusters: per-cluster CS logs
        for cid in "${CLUSTER_IDS[@]}"; do
          local_dir="${RHOBS_LOG_BASE}/${cid}"
          mkdir -p "${local_dir}"
          echo "  Querying CS provisioning logs for cluster ${cid}..."
          query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"${cid}\" |!= \"[ROSA HCP -\"" \
            "${local_dir}/cs-provisioning.txt"
        done

        # CS telemetry events (generic, shared across all clusters)
        echo "  Querying CS telemetry events..."
        query_loki "{k8s_namespace_name=\"${CS_NS}\"} |= \"[ROSA HCP -\"" \
          "${RHOBS_LOG_BASE}/cs-telemetry.txt" 5000
      fi
    else
      echo "WARNING: Failed to get RHOBS OIDC token, skipping all RHOBS logs"
    fi
  fi
else
  echo "No RHOBS OIDC credentials found, skipping RHOBS log collection"
fi

# Summary
echo ""
echo "=== RHOBS Log Collection Summary ==="
find "${RHOBS_LOG_BASE}" -name "*.txt" -type f | sort | while read -r f; do
  rel_path="${f#"${RHOBS_LOG_BASE}/"}"
  lines=$(wc -l < "$f" 2>/dev/null || echo "0")
  size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
  echo "  ${rel_path}: ${lines} lines (${size})"
done
