#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id" 2>/dev/null || echo "")
if [[ -z "${CLUSTER_ID}" ]]; then
  echo "No cluster-id found, skipping RHOBS log collection."
  exit 0
fi

RHOBS_LOG_DIR="${ARTIFACT_DIR}/rhobs-logs"
mkdir -p "${RHOBS_LOG_DIR}"

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

MC_CLUSTER_ID=""
if [[ "${OCM_LOGGED_IN}" == "true" ]]; then
  if [[ -f "${SHARED_DIR}/mc-cluster-name" ]]; then
    MC_NAME=$(cat "${SHARED_DIR}/mc-cluster-name")
    MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id' 2>/dev/null || echo "")
  else
    MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard 2>/dev/null | jq -r .management_cluster || echo "")
    if [[ -n "${MC_NAME}" && "${MC_NAME}" != "null" ]]; then
      MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id' 2>/dev/null || echo "")
    fi
  fi
fi

HIVE_OCM_URL="${RHOBS_HIVE_OCM_URL:-staging}"
SINCE="${RHOBS_LOG_SINCE:-3h}"

echo "=== RHOBS Log Collection ==="
echo "Cluster ID: ${CLUSTER_ID}"
echo "MC: ${MC_NAME:-unknown} (${MC_CLUSTER_ID:-unknown})"
echo ""

collect_logs() {
  local label="$1"
  local output="$2"
  shift 2
  echo "Collecting ${label}..."
  osdctl rhobs logs "$@" 2>&1 | grep -v "^time=\|^Vault" > "${RHOBS_LOG_DIR}/${output}" || true
}

if [[ -n "${MC_CLUSTER_ID}" && "${MC_CLUSTER_ID}" != "null" ]]; then

  # 1. HCP guest cluster logs (etcd, kube-apiserver, etc.) from the sub-namespace
  collect_logs "HCP guest cluster logs" "hcp-guest-cluster.log" \
    -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
    --query "{k8s_namespace_name=~\"ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-.*\"}" \
    --since "${SINCE}" --limit 50000 --direction forward -o text

  # 2. HyperShift operator logs filtered for this cluster
  collect_logs "HyperShift operator logs (this cluster)" "hypershift-operator.log" \
    -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
    -n "hypershift" --contain "${CLUSTER_ID}" \
    --since "${SINCE}" --limit 10000 --direction forward -o text

  # 3. HyperShift operator (all logs, for broader context)
  collect_logs "HyperShift operator logs (all)" "hypershift-operator-all.log" \
    -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
    -n "hypershift" \
    --since "${SINCE}" --limit 10000 --direction forward -o text

  # 4. MCO logs (ClusterImagePolicy rollout)
  collect_logs "MCO logs" "mco.log" \
    -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
    -n "openshift-machine-config-operator" \
    --since "${SINCE}" --limit 5000 --direction forward -o text

  # 5. ACM logs
  collect_logs "ACM logs" "acm.log" \
    -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
    -n "open-cluster-management" \
    --since "${SINCE}" --limit 5000 --direction forward -o text

  # 6. cert-manager logs
  collect_logs "cert-manager logs" "cert-manager.log" \
    -C "${MC_CLUSTER_ID}" --hive-ocm-url "${HIVE_OCM_URL}" \
    -n "cert-manager" \
    --since "${SINCE}" --limit 5000 --direction forward -o text
fi

# 7. CS provisioning logs via RHOBS Loki API (global cell)
if [[ -f /usr/local/rhobs-oidc/client_id ]]; then
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
        since_seconds=$(( ${BASH_REMATCH[1]} * 3600 ))
      elif [[ "${SINCE}" =~ ^([0-9]+)m$ ]]; then
        since_seconds=$(( ${BASH_REMATCH[1]} * 60 ))
      fi
      START_NS=$(( ($(date +%s) - since_seconds) * 1000000000 ))
      END_NS=$(( $(date +%s) * 1000000000 ))

      # CS logs mentioning this cluster ID
      curl -sf --max-time 120 \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query={k8s_namespace_name=\"${CS_NS}\"} |= \"${CLUSTER_ID}\"" \
        --data-urlencode "start=${START_NS}" \
        --data-urlencode "end=${END_NS}" \
        --data-urlencode "limit=10000" \
        --data-urlencode "direction=forward" \
        -G "$LOKI_BASE/query_range" 2>/dev/null | \
        python3 -c "
import sys, json
d = json.load(sys.stdin)
for stream in d.get('data',{}).get('result',[]):
    for ts_ns, msg in stream.get('values',[]):
        print(msg)
" > "${RHOBS_LOG_DIR}/cs-provisioning.log" 2>/dev/null || true

      # CS telemetry events (ROSA HCP lifecycle tags)
      curl -sf --max-time 120 \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query={k8s_namespace_name=\"${CS_NS}\"} |= \"[ROSA HCP -\"" \
        --data-urlencode "start=${START_NS}" \
        --data-urlencode "end=${END_NS}" \
        --data-urlencode "limit=5000" \
        --data-urlencode "direction=forward" \
        -G "$LOKI_BASE/query_range" 2>/dev/null | \
        python3 -c "
import sys, json
d = json.load(sys.stdin)
for stream in d.get('data',{}).get('result',[]):
    for ts_ns, msg in stream.get('values',[]):
        print(msg)
" > "${RHOBS_LOG_DIR}/cs-telemetry.log" 2>/dev/null || true
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
for f in "${RHOBS_LOG_DIR}"/*.log; do
  if [[ -f "$f" ]]; then
    lines=$(wc -l < "$f" 2>/dev/null || echo "0")
    size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
    echo "  $(basename "$f"): ${lines} lines (${size})"
  fi
done
