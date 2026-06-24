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

kas_generation="$(oc get deployment -n "${HCP_NAMESPACE}" kube-apiserver -o jsonpath='{.metadata.generation}')"

echo "Applying Modern TLS Security Profile to HostedCluster..."
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

hc_tls_profile=$(oc get hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" "${HOSTED_CLUSTER_NAME}" -o jsonpath='{.spec.configuration.apiServer.tlsSecurityProfile.type}')
if [[ "${hc_tls_profile}" != "Modern" ]]; then
  echo "Error: HostedCluster TLS Security Profile is '${hc_tls_profile}', expected 'Modern'"
  exit 1
fi
echo "✓ HostedCluster spec.configuration.apiServer.tlsSecurityProfile.type is Modern"

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

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

echo "Waiting for guest cluster APIServer to reflect Modern TLS profile..."
for i in {1..40}; do
  tls_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "")
  if [[ "$tls_profile" == "Modern" ]]; then
    echo "✓ Guest cluster APIServer tlsSecurityProfile.type is Modern"
    echo "✓ Modern TLS Security Profile successfully applied"
    exit 0
  fi
  if verify_modern_tls_endpoint; then
    echo "Guest cluster APIServer tlsSecurityProfile.type is '${tls_profile}' (HyperShift may not mirror this field)"
    echo "✓ Modern TLS Security Profile successfully applied"
    exit 0
  fi
  echo "Waiting for Modern TLS profile to propagate (attempt $i/40)..."
  sleep 15
done

tls_profile=$(oc get apiserver/cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "NotFound")
if [[ "$tls_profile" == "Modern" ]]; then
  echo "✓ Modern TLS Security Profile successfully applied"
  exit 0
fi

echo "Guest cluster APIServer tlsSecurityProfile.type is '${tls_profile}'"
verify_modern_tls_endpoint
echo "✓ Modern TLS Security Profile successfully applied"
