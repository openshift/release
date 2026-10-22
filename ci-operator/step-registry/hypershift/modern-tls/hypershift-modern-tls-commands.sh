#!/bin/bash
set -euo pipefail

echo "Configuring Modern TLS Security Profile for HyperShift cluster..."

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
  HOSTED_CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
  HOSTED_CLUSTER_NAMESPACE="clusters"
else
  HOSTED_CLUSTER_NAME=$(oc get hostedcluster -A -o jsonpath='{.items[0].metadata.name}')
  HOSTED_CLUSTER_NAMESPACE=$(oc get hostedcluster -A -o jsonpath='{.items[0].metadata.namespace}')
fi

if [[ -z "${HOSTED_CLUSTER_NAME}" ]]; then
  echo "Error: Could not find HostedCluster"
  exit 1
fi

HCP_NAMESPACE=$(oc get hostedcontrolplane -A -o jsonpath="{.items[?(@.metadata.name==\"${HOSTED_CLUSTER_NAME}\")].metadata.namespace}" 2>/dev/null || true)
if [[ -z "${HCP_NAMESPACE}" ]]; then
  HCP_NAMESPACE="clusters-${HOSTED_CLUSTER_NAME}"
fi

echo "Found HostedCluster: ${HOSTED_CLUSTER_NAME} in namespace ${HOSTED_CLUSTER_NAMESPACE}"
echo "Hosted control plane namespace: ${HCP_NAMESPACE}"

NODEPOOL_CONFIG_VERSION_ANNOTATION="hypershift.openshift.io/nodePoolCurrentConfigVersion"
NODEPOOL_CONFIG_ANNOTATION="hypershift.openshift.io/nodePoolCurrentConfig"

nodepool_annotation() {
  local nodepool_name=$1
  local annotation_key=$2
  oc get "nodepool/${nodepool_name}" -n "${HOSTED_CLUSTER_NAMESPACE}" \
    -o go-template="{{index .metadata.annotations \"${annotation_key}\"}}"
}

nodepool_config_version() {
  nodepool_annotation "$1" "${NODEPOOL_CONFIG_VERSION_ANNOTATION}"
}

nodepool_current_config() {
  nodepool_annotation "$1" "${NODEPOOL_CONFIG_ANNOTATION}"
}

nodepool_condition_status() {
  local nodepool_name=$1
  local condition_type=$2
  oc get "nodepool/${nodepool_name}" -n "${HOSTED_CLUSTER_NAMESPACE}" \
    -o jsonpath="{.status.conditions[?(@.type==\"${condition_type}\")].status}" 2>/dev/null || true
}

mapfile -t NODEPOOLS < <(oc get nodepool -n "${HOSTED_CLUSTER_NAMESPACE}" \
  -o jsonpath="{range .items[?(@.spec.clusterName==\"${HOSTED_CLUSTER_NAME}\")]}{.metadata.name}{\"\\n\"}{end}")
if [[ ${#NODEPOOLS[@]} -eq 0 ]]; then
  mapfile -t NODEPOOLS < <(oc get nodepool -n "${HOSTED_CLUSTER_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
fi

declare -A NODEPOOL_BASELINE_CONFIG_VERSIONS=()
declare -A NODEPOOL_BASELINE_CONFIG_HASHES=()
if [[ ${#NODEPOOLS[@]} -eq 0 ]]; then
  echo "Warning: no NodePools found for HostedCluster ${HOSTED_CLUSTER_NAME}"
else
  echo "Recording NodePool config versions before TLS change..."
  for np in "${NODEPOOLS[@]}"; do
    baseline_version=""
    baseline_config=""
    for _ in $(seq 1 40); do
      baseline_version="$(nodepool_config_version "${np}")"
      baseline_config="$(nodepool_current_config "${np}")"
      if [[ -n "${baseline_version}" ]]; then
        break
      fi
      echo "  NodePool/${np}: waiting for ${NODEPOOL_CONFIG_VERSION_ANNOTATION} to be set..."
      sleep 15
    done
    if [[ -z "${baseline_version}" ]]; then
      echo "Error: could not read ${NODEPOOL_CONFIG_VERSION_ANNOTATION} on NodePool/${np} before TLS change"
      oc get "nodepool/${np}" -n "${HOSTED_CLUSTER_NAMESPACE}" -o yaml || true
      exit 1
    fi
    NODEPOOL_BASELINE_CONFIG_VERSIONS["${np}"]="${baseline_version}"
    NODEPOOL_BASELINE_CONFIG_HASHES["${np}"]="${baseline_config}"
    echo "  NodePool/${np}: ${NODEPOOL_CONFIG_VERSION_ANNOTATION}='${baseline_version}', ${NODEPOOL_CONFIG_ANNOTATION}='${baseline_config}'"
  done
fi

kas_generation="$(oc get deployment -n "${HCP_NAMESPACE}" kube-apiserver -o jsonpath='{.metadata.generation}')"

case "${TLS_13_ENABLE_TLS_ADHERENCE:-}" in
true)
  case "${TLS_13_TLS_ADHERENCE_POLICY}" in
  LegacyAdheringComponentsOnly|StrictAllComponents) ;;
  *)
    echo "Invalid TLS_13_TLS_ADHERENCE_POLICY='${TLS_13_TLS_ADHERENCE_POLICY}' (expected LegacyAdheringComponentsOnly or StrictAllComponents)"
    exit 1
    ;;
  esac
  ;;
false|"")
  ;;
*)
  echo "Invalid TLS_13_ENABLE_TLS_ADHERENCE='${TLS_13_ENABLE_TLS_ADHERENCE}' (expected literal \"true\" or \"false\")"
  exit 1
  ;;
esac

echo "Applying Modern TLS Security Profile to HostedCluster..."
if [[ "${TLS_13_ENABLE_TLS_ADHERENCE:-}" == "true" ]]; then
  oc patch hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" --type=merge -p "{
    \"spec\": {
      \"configuration\": {
        \"apiServer\": {
          \"tlsAdherence\": \"${TLS_13_TLS_ADHERENCE_POLICY}\",
          \"tlsSecurityProfile\": {
            \"type\": \"Modern\",
            \"modern\": {}
          }
        }
      }
    }
  }"
else
  oc patch hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" --type=merge -p '{
    "spec": {
      "configuration": {
        "apiServer": {
          "tlsSecurityProfile": {
            "type": "Modern",
            "modern": {}
          }
        }
      }
    }
  }'
fi

hc_tls_profile=$(oc get hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" -o jsonpath='{.spec.configuration.apiServer.tlsSecurityProfile.type}')
if [[ "${hc_tls_profile}" != "Modern" ]]; then
  echo "Error: HostedCluster TLS Security Profile is '${hc_tls_profile}', expected 'Modern'"
  exit 1
fi
echo "✓ HostedCluster spec.configuration.apiServer.tlsSecurityProfile.type is Modern"

if [[ "${TLS_13_ENABLE_TLS_ADHERENCE:-}" == "true" ]]; then
  hc_tls_adherence=$(oc get hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" -o jsonpath='{.spec.configuration.apiServer.tlsAdherence}')
  if [[ "${hc_tls_adherence}" != "${TLS_13_TLS_ADHERENCE_POLICY}" ]]; then
    echo "Error: HostedCluster tlsAdherence is '${hc_tls_adherence}', expected '${TLS_13_TLS_ADHERENCE_POLICY}'"
    exit 1
  fi
  echo "✓ HostedCluster spec.configuration.apiServer.tlsAdherence is ${hc_tls_adherence}"
fi

echo "Waiting for kube-apiserver to reconcile the TLS profile..."
rollout_deadline=$((SECONDS + 300))
while (( SECONDS < rollout_deadline )); do
  current_generation="$(oc get deployment -n "${HCP_NAMESPACE}" kube-apiserver -o jsonpath='{.metadata.generation}')"
  if (( current_generation > kas_generation )); then
    echo "kube-apiserver generation changed (${kas_generation} -> ${current_generation}), waiting for rollout..."
    oc rollout status deployment -n "${HCP_NAMESPACE}" kube-apiserver --timeout=15m
    break
  fi
  sleep 15
done
if (( SECONDS >= rollout_deadline )); then
  echo "kube-apiserver generation unchanged after 5m; continuing with TLS verification"
fi

echo "Waiting for all control plane deployments to finish rolling out..."
HCP_DEPLOYMENTS=$(oc get deployments -n "${HCP_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}')
for dep in ${HCP_DEPLOYMENTS}; do
  echo "  Waiting for deployment/${dep}..."
  oc rollout status deployment/"${dep}" -n "${HCP_NAMESPACE}" --timeout=15m || {
    echo "  Warning: deployment/${dep} rollout did not complete within timeout"
  }
done
echo "All control plane deployments rolled out."

wait_nodepool_rollout() {
  if [[ ${#NODEPOOLS[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Waiting for NodePool config rollout after HostedCluster TLS configuration change..."
  local timeout_seconds
  timeout_seconds="${NODEPOOL_ROLLOUT_TIMEOUT_SECONDS:-3600}"
  local deadline=$((SECONDS + timeout_seconds))

  for np in "${NODEPOOLS[@]}"; do
    local baseline_version="${NODEPOOL_BASELINE_CONFIG_VERSIONS[${np}]}"
    local baseline_config="${NODEPOOL_BASELINE_CONFIG_HASHES[${np}]}"
    local rollout_complete=false
    local saw_updating_config=false

    echo "  Waiting for NodePool/${np} config rollout (version baseline='${baseline_version}', config baseline='${baseline_config}')..."
    while (( SECONDS < deadline )); do
      local current_version current_config updating_config all_healthy
      current_version="$(nodepool_config_version "${np}")"
      current_config="$(nodepool_current_config "${np}")"
      updating_config="$(nodepool_condition_status "${np}" "UpdatingConfig")"
      all_healthy="$(nodepool_condition_status "${np}" "AllNodesHealthy")"

      if [[ "${updating_config}" == "True" ]]; then
        saw_updating_config=true
      fi

      if [[ -n "${current_version}" && "${current_version}" != "${baseline_version}" ]]; then
        echo "  ✓ NodePool/${np} config version rolled out: '${baseline_version}' -> '${current_version}'"
        rollout_complete=true
        break
      fi
      if [[ -n "${baseline_config}" && -n "${current_config}" && "${current_config}" != "${baseline_config}" ]]; then
        echo "  ✓ NodePool/${np} config hash rolled out: '${baseline_config}' -> '${current_config}'"
        rollout_complete=true
        break
      fi
      if [[ "${saw_updating_config}" == "true" && "${updating_config}" == "False" && "${all_healthy}" == "True" ]]; then
        echo "  ✓ NodePool/${np} finished UpdatingConfig with AllNodesHealthy=True (version='${current_version}')"
        rollout_complete=true
        break
      fi
      sleep 15
    done

    if [[ "${rollout_complete}" != "true" ]]; then
      local current_version current_config updating_config all_healthy
      current_version="$(nodepool_config_version "${np}")"
      current_config="$(nodepool_current_config "${np}")"
      updating_config="$(nodepool_condition_status "${np}" "UpdatingConfig")"
      all_healthy="$(nodepool_condition_status "${np}" "AllNodesHealthy")"
      if [[ "${updating_config}" == "False" && "${all_healthy}" == "True" && "${current_version}" == "${baseline_version}" ]]; then
        echo "  Warning: NodePool/${np} ${NODEPOOL_CONFIG_VERSION_ANNOTATION} remained '${current_version}' but NodePool is healthy; continuing"
      else
        echo "Error: timed out waiting for NodePool/${np} config rollout (version='${current_version:-<empty>}', UpdatingConfig='${updating_config}', AllNodesHealthy='${all_healthy}')"
        oc get "nodepool/${np}" -n "${HOSTED_CLUSTER_NAMESPACE}" -o yaml || true
        return 1
      fi
    fi

    echo "  Waiting for NodePool/${np} AllNodesHealthy=True..."
    oc wait "nodepool/${np}" -n "${HOSTED_CLUSTER_NAMESPACE}" \
      --for=condition=AllNodesHealthy=True --timeout="${NODEPOOL_ROLLOUT_TIMEOUT}"
  done
  echo "✓ NodePool config rollout complete"
}

wait_nodepool_rollout

verify_modern_tls_endpoint() {
  local api_server api_host api_port

  api_server="$(oc whoami --show-server)"
  api_host="${api_server#https://}"
  api_host="${api_host%:*}"
  api_port="${api_server##*:}"

  echo "Verifying Modern TLS profile on API server endpoint ${api_host}:${api_port}..."
  if ! echo | openssl s_client -connect "${api_host}:${api_port}" -tls1_3 -servername "${api_host}" 2>/dev/null | grep -qE 'Protocol.*TLSv1\.3'; then
    echo "Error: API server does not negotiate TLS 1.3"
    return 1
  fi
  if echo | openssl s_client -connect "${api_host}:${api_port}" -tls1_2 -servername "${api_host}" 2>/dev/null | grep -qE 'Protocol.*TLSv1\.2'; then
    echo "Error: API server still negotiates TLS 1.2 (expected Modern profile)"
    return 1
  fi
  echo "✓ API server endpoint enforces Modern TLS (TLS 1.3 only)"
}

wait_guest_machine_config_pools() {
  echo "Checking guest cluster MachineConfigPools..."
  local mcp_names
  if ! mcp_names="$(oc get mcp -o name 2>&1)"; then
    if [[ "${mcp_names}" == *"(NotFound)"* ]]; then
      echo "MachineConfigPool API is not available on guest cluster; skipping MCP wait"
      return 0
    fi
    echo "Error: failed to list MachineConfigPools: ${mcp_names}" >&2
    return 1
  fi

  if [[ -z "${mcp_names//[$'\t\r\n ']/}" ]]; then
    echo "No MachineConfigPools on guest cluster; skipping MCP wait (node rollout validated via NodePool)"
    return 0
  fi

  echo "Waiting for all MachineConfigPools to finish updating on guest cluster..."
  local deadline=$((SECONDS + MCP_ROLLOUT_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if oc wait mcp --all --for=condition=UPDATED=True --timeout=30s && \
       oc wait mcp --all --for=condition=UPDATING=False --timeout=30s && \
       oc wait mcp --all --for=condition=DEGRADED=False --timeout=30s; then
      echo "✓ All MachineConfigPools are updated"
      return 0
    fi
    echo "MachineConfigPools still updating..."
    sleep 15
  done
  echo "Error: timed out waiting for MachineConfigPools"
  oc get mcp -o wide || true
  return 1
}

wait_guest_tuned_daemonset() {
  echo "Waiting for tuned DaemonSet on all guest nodes..."
  local tuned_lookup
  if ! tuned_lookup="$(oc -n openshift-cluster-node-tuning get ds/tuned -o name 2>&1)"; then
    if [[ "${tuned_lookup}" == *"(NotFound)"* ]]; then
      echo "Warning: tuned DaemonSet not found in openshift-cluster-node-tuning; skipping tuned readiness check"
      return 0
    fi
    echo "Error: failed to look up tuned DaemonSet: ${tuned_lookup}" >&2
    return 1
  fi

  oc wait --for=condition=Available ds/tuned -n openshift-cluster-node-tuning --timeout="${TUNED_ROLLOUT_TIMEOUT}"

  local desired ready
  desired=$(oc get ds/tuned -n openshift-cluster-node-tuning -o jsonpath='{.status.desiredNumberScheduled}')
  ready=$(oc get ds/tuned -n openshift-cluster-node-tuning -o jsonpath='{.status.numberReady}')
  if [[ -z "${desired}" || "${desired}" -eq 0 ]]; then
    echo "Warning: tuned DaemonSet has no scheduled pods"
    return 0
  fi
  if [[ "${ready}" -lt "${desired}" ]]; then
    echo "Error: tuned DaemonSet has ${ready}/${desired} ready pods"
    oc get pods -n openshift-cluster-node-tuning -o wide || true
    return 1
  fi
  echo "✓ tuned DaemonSet ready on ${ready}/${desired} nodes"
}

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

echo "Waiting for guest cluster APIServer to reflect Modern TLS profile..."
guest_tls_verified=false
for i in {1..40}; do
  tls_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "")
  if [[ "$tls_profile" == "Modern" ]]; then
    echo "✓ Guest cluster APIServer tlsSecurityProfile.type is Modern"
    guest_tls_verified=true
    break
  fi
  if verify_modern_tls_endpoint; then
    echo "Guest cluster APIServer tlsSecurityProfile.type is '${tls_profile}' (HyperShift may not mirror this field)"
    guest_tls_verified=true
    break
  fi
  echo "Waiting for Modern TLS profile to propagate (attempt $i/40)..."
  sleep 15
done

if [[ "${guest_tls_verified}" != "true" ]]; then
  tls_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "NotFound")
  echo "Guest cluster APIServer tlsSecurityProfile.type is '${tls_profile}'"
  verify_modern_tls_endpoint
fi

if oc adm wait-for-stable-cluster --help >/dev/null 2>&1; then
  echo "Waiting for guest cluster to become stable..."
  oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout="${GUEST_STABLE_CLUSTER_TIMEOUT}"
else
  echo "Warning: oc adm wait-for-stable-cluster is not available; skipping cluster stability wait"
fi

wait_guest_machine_config_pools
wait_guest_tuned_daemonset

if [[ "${TLS_13_ENABLE_TLS_ADHERENCE:-}" == "true" ]]; then
  guest_tls_adherence=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsAdherence}' 2>/dev/null || echo "")
  if [[ -n "${guest_tls_adherence}" && "${guest_tls_adherence}" != "${TLS_13_TLS_ADHERENCE_POLICY}" ]]; then
    echo "Error: guest APIServer tlsAdherence is '${guest_tls_adherence}', expected '${TLS_13_TLS_ADHERENCE_POLICY}'"
    exit 1
  fi
  if [[ "${guest_tls_adherence}" == "${TLS_13_TLS_ADHERENCE_POLICY}" ]]; then
    echo "✓ Guest cluster APIServer tlsAdherence is ${guest_tls_adherence}"
  else
    echo "Guest cluster APIServer tlsAdherence is not mirrored yet (HyperShift may only enforce via node rollout)"
  fi
fi

echo "✓ Modern TLS Security Profile successfully applied and node rollout complete"
