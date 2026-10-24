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
        TOKEN="${TOKEN}" python3 - "${query}" "${output_file}" "${limit}" "${START_NS}" "${END_NS}" "${LOKI_BASE}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

query, output, limit, start, end, base = sys.argv[1:]
output = Path(output)
status = {"outcome": "transport_error", "entries": 0, "curl_exit": None,
          "http_status": None, "output_cleanup_failed": False}


def atomic_write(path, contents):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".rhobs-", delete=False) as handle:
            temporary = handle.name
            handle.write(contents)
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


def messages_from_response(response):
    if not isinstance(response, dict):
        return "schema_error", []
    if response.get("status") == "error":
        return "api_error", []
    data = response.get("data")
    if (response.get("status") != "success" or not isinstance(data, dict)
            or data.get("resultType") != "streams" or not isinstance(data.get("result"), list)):
        return "schema_error", []
    messages = []
    for stream in data["result"]:
        if not isinstance(stream, dict) or not isinstance(stream.get("values"), list):
            return "schema_error", []
        for entry in stream["values"]:
            if (not isinstance(entry, list) or len(entry) != 2
                    or not isinstance(entry[0], str) or not entry[0].isdigit()
                    or not isinstance(entry[1], str)):
                return "schema_error", []
            messages.append(entry[1])
    return ("success_nonempty" if messages else "success_empty"), messages


messages = []
try:
    result = subprocess.run([
        "curl", "-sf", "--max-time", "120",
        "-H", "Authorization: Bearer " + os.environ.pop("TOKEN"),
        "--data-urlencode", "query=" + query,
        "--data-urlencode", "start=" + start,
        "--data-urlencode", "end=" + end,
        "--data-urlencode", "limit=" + limit,
        "--data-urlencode", "direction=forward",
        "-w", "\n%{http_code}", "-G", base + "/query_range",
    ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    status["curl_exit"] = result.returncode
    body, separator, http_code = result.stdout.rpartition(b"\n")
    if separator and len(http_code) == 3 and http_code.isdigit():
        status["http_status"] = int(http_code)
    if result.returncode == 28:
        status["outcome"] = "timeout"
    elif result.returncode == 22:
        status["outcome"] = "http_error"
    elif result.returncode != 0:
        status["outcome"] = "transport_error"
    elif status["http_status"] is None:
        status["outcome"] = "transport_error"
    elif not 200 <= status["http_status"] < 300:
        status["outcome"] = "http_error"
    else:
        try:
            response = json.loads(body)
        except (ValueError, UnicodeError, RecursionError):
            status["outcome"] = "malformed_json"
        else:
            status["outcome"], messages = messages_from_response(response)
except OSError:
    status["outcome"] = "transport_error"

try:
    if status["outcome"].startswith("success_"):
        atomic_write(output, "".join(message + "\n" for message in messages))
        status["entries"] = len(messages)
except (OSError, UnicodeError):
    status["outcome"] = "output_error"

if not status["outcome"].startswith("success_"):
    status["entries"] = 0
    try:
        output.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        status["outcome"] = "output_error"
        status["output_cleanup_failed"] = True

sidecar = "written"
sidecar_path = Path(str(output) + ".status.json")
try:
    atomic_write(sidecar_path, json.dumps(status) + "\n")
except OSError:
    sidecar = "write_error"
    try:
        sidecar_path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        sidecar = "write_error_cleanup_failed"
print("    Loki outcome: {} outcome={} entries={} curl_exit={} http_status={} sidecar={} output_cleanup_failed={}".format(
    output.name, status["outcome"], status["entries"], status["curl_exit"],
    status["http_status"], sidecar, status["output_cleanup_failed"]), flush=True)
PY
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

        # 2-4. OVN-K / CNCC / EgressIP logs (parallelized to stay within step timeout)
        echo "  Collecting OVN-K, CNCC, and EgressIP logs in parallel..."
        query_loki "{k8s_namespace_name=~\"ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-.*\", k8s_container_name=~\"ovnkube-controller.*\"}" \
          "${RHOBS_LOG_DIR}/ovnkube-controller.txt" 10000 &
        query_loki "{k8s_namespace_name=~\"ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-.*\", k8s_container_name=~\"cloud-network-config-controller.*\"}" \
          "${RHOBS_LOG_DIR}/cloud-network-config-controller.txt" 5000 &
        query_loki "{k8s_namespace_name=~\"ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-.*\"} |~ \"(?i)egressip|egress[._-]?ip|egressnode|EgressIPAM\"" \
          "${RHOBS_LOG_DIR}/egressip-filtered.txt" 5000 &
        wait

        # 5. HyperShift operator logs filtered for this cluster
        echo "  Collecting HyperShift operator logs (this cluster)..."
        query_loki "{k8s_namespace_name=\"hypershift\"} |= \"${CLUSTER_ID}\"" \
          "${RHOBS_LOG_DIR}/hypershift-operator.txt" 10000

        # 6. HyperShift operator (all logs)
        echo "  Collecting HyperShift operator logs (all)..."
        query_loki "{k8s_namespace_name=\"hypershift\"}" \
          "${RHOBS_LOG_DIR}/hypershift-operator-all.txt" 10000

        # 7. MCO logs
        echo "  Collecting MCO logs..."
        query_loki "{k8s_namespace_name=\"openshift-machine-config-operator\"}" \
          "${RHOBS_LOG_DIR}/mco.txt" 5000

        # 8. ACM logs
        echo "  Collecting ACM logs..."
        query_loki "{k8s_namespace_name=\"open-cluster-management-agent-addon\"}" \
          "${RHOBS_LOG_DIR}/acm.txt" 5000

        # 9. cert-manager logs
        echo "  Collecting cert-manager logs..."
        query_loki "{k8s_namespace_name=\"cert-manager\"}" \
          "${RHOBS_LOG_DIR}/cert-manager.txt" 5000

        # 10. Route Monitor Operator logs
        echo "  Collecting Route Monitor Operator logs..."
        query_loki "{k8s_namespace_name=\"openshift-route-monitor-operator\"}" \
          "${RHOBS_LOG_DIR}/route-monitor-operator-logs.txt" 5000

        # 11. AWS VPCE Operator logs
        echo "  Collecting AWS VPCE Operator logs..."
        query_loki "{k8s_namespace_name=\"openshift-aws-vpce-operator\"}" \
          "${RHOBS_LOG_DIR}/aws-vpce-operator-logs.txt" 5000

        # 12. Cluster-side EgressIP diagnostic state (requires guest cluster kubeconfig)
        if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
          echo "  Collecting cluster-side EgressIP state (guest cluster)..."
          oc --kubeconfig="${SHARED_DIR}/kubeconfig" get egressips -o yaml \
            > "${RHOBS_LOG_DIR}/egressip-cluster-state.txt" 2>&1 || true

          oc --kubeconfig="${SHARED_DIR}/kubeconfig" get nodes -l k8s.ovn.org/egress-assignable -o json 2>/dev/null | \
            jq '.items[] | {name: .metadata.name, annotations: {ifaddr: .metadata.annotations["k8s.ovn.org/node-primary-ifaddr"], ipconfig: .metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]}}' \
            > "${RHOBS_LOG_DIR}/egressip-node-annotations.json" 2>&1 || true

          oc --kubeconfig="${SHARED_DIR}/kubeconfig" get events --field-selector reason=EgressIPAssignmentError --sort-by=.lastTimestamp -A \
            > "${RHOBS_LOG_DIR}/egressip-events.txt" 2>&1 || true
        else
          echo "  Skipping cluster-side EgressIP state collection (no guest cluster kubeconfig at ${SHARED_DIR}/kubeconfig)"
        fi
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
