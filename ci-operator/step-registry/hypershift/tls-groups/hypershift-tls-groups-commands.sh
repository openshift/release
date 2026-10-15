#!/bin/bash
set -euo pipefail

echo "Configuring Custom TLS Security Profile with named groups for HyperShift cluster..."

export KUBECONFIG=${SHARED_DIR}/kubeconfig

TLS_GROUPS_LIST="${TLS_GROUPS:-SecP384r1MLKEM1024}"
TLS_GROUPS_MIN_VERSION="${TLS_GROUPS_MIN_VERSION:-VersionTLS13}"
if [[ "${TLS_GROUPS_MIN_VERSION}" != "VersionTLS13" ]]; then
  echo "TLS_GROUPS_MIN_VERSION must be VersionTLS13; Custom profile omits ciphers (TLS 1.3 suites are not configurable)"
  exit 1
fi

groups_json=$(printf '%s' "${TLS_GROUPS_LIST}" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')
if [[ "$(echo "${groups_json}" | jq 'length')" -lt 1 ]]; then
  echo "TLS_GROUPS must contain at least one group"
  exit 1
fi

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
echo "TLS groups: ${groups_json}"

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

hc_patch=$(jq -nc --argjson groups "${groups_json}" --arg minver "${TLS_GROUPS_MIN_VERSION}" '
  {
    spec: {
      configuration: {
        apiServer: {
          tlsSecurityProfile: {
            type: "Custom",
            custom: {
              minTLSVersion: $minver,
              groups: $groups
            }
          }
        }
      }
    }
  }
')

echo "Applying Custom TLS Security Profile with groups to HostedCluster..."
echo "${hc_patch}" | jq .
oc patch hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" --type=merge -p "${hc_patch}"

hc_tls_profile=$(oc get hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" -o jsonpath='{.spec.configuration.apiServer.tlsSecurityProfile.type}')
if [[ "${hc_tls_profile}" != "Custom" ]]; then
  echo "Error: HostedCluster TLS Security Profile is '${hc_tls_profile}', expected 'Custom'"
  exit 1
fi
hc_groups=$(oc get hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" -o json | jq -c '.spec.configuration.apiServer.tlsSecurityProfile.custom.groups // []')
if [[ "${hc_groups}" != "${groups_json}" ]]; then
  echo "Error: HostedCluster custom.groups is '${hc_groups}', expected '${groups_json}'"
  echo "If groups disappeared, TLSGroupPreferences may not be active on this HyperShift operator/payload."
  exit 1
fi
echo "✓ HostedCluster spec.configuration.apiServer.tlsSecurityProfile is Custom with groups=${hc_groups}"

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

echo "Waiting for guest cluster APIServer to reflect Custom TLS profile with groups..."
guest_tls_verified=false
for i in {1..40}; do
  tls_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "")
  observed_groups=$(oc get apiserver/cluster -o json 2>/dev/null | jq -c '.spec.tlsSecurityProfile.custom.groups // []' || echo "[]")
  if [[ "$tls_profile" == "Custom" && "${observed_groups}" == "${groups_json}" ]]; then
    echo "✓ Guest cluster APIServer tlsSecurityProfile is Custom with groups=${observed_groups}"
    guest_tls_verified=true
    break
  fi
  echo "Waiting for Custom TLS groups to propagate (attempt $i/40; type='${tls_profile}', groups='${observed_groups}')..."
  sleep 15
done

if [[ "${guest_tls_verified}" != "true" ]]; then
  tls_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "NotFound")
  observed_groups=$(oc get apiserver/cluster -o json 2>/dev/null | jq -c '.spec.tlsSecurityProfile.custom.groups // []' || echo "[]")
  echo "Guest cluster APIServer tlsSecurityProfile.type is '${tls_profile}', groups='${observed_groups}'"
  echo "Warning: HyperShift may not mirror HostedCluster custom.groups into guest APIServer/cluster; continuing (scanner will assert endpoints)"
fi

if oc adm wait-for-stable-cluster --help >/dev/null 2>&1; then
  echo "Waiting for guest cluster to become stable..."
  oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout="${GUEST_STABLE_CLUSTER_TIMEOUT}"
else
  echo "Warning: oc adm wait-for-stable-cluster is not available; skipping cluster stability wait"
fi

wait_guest_machine_config_pools
wait_guest_tuned_daemonset

echo "✓ HostedCluster Custom TLS profile with groups applied and node rollout complete"
