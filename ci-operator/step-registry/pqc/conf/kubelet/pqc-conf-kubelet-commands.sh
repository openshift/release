#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Set proxy if configured
if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    echo "[INFO] Setting proxy configuration"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Build TLS security profile configuration
tls_config=$(jq -nc \
  --arg cipher "${PQC_CIPHER}" \
  --arg minVersion "${PQC_MIN_TLS_VERSION}" \
  '{
    "type": "Custom",
    "custom": {
      "ciphers": [$cipher],
      "minTLSVersion": $minVersion
    }
  }')

echo "[INFO] Configuring Kubelet with PQC TLS profile:"
echo "${tls_config}" | jq .

# Create KubeletConfig resource
echo "[INFO] Creating KubeletConfig resource targeting MCP: ${PQC_KUBELET_MCP}..."
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: pqc-tls-config
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${PQC_KUBELET_MCP}: ""
  tlsSecurityProfile: ${tls_config}
EOF

# Verify the MCP exists
if ! oc get mcp "${PQC_KUBELET_MCP}" &>/dev/null; then
    echo "[ERROR] Machine Config Pool '${PQC_KUBELET_MCP}' not found"
    echo "[INFO] Available Machine Config Pools:"
    oc get mcp
    exit 1
fi

# Wait for MCP to start updating
echo "[INFO] Waiting for Machine Config Pool '${PQC_KUBELET_MCP}' to start updating (max 5 minutes)..."
if ! oc wait mcp/${PQC_KUBELET_MCP} --for condition=Updating=True --timeout=5m; then
    echo "[WARN] MCP did not enter Updating state within 5 minutes, checking current state..."
    oc get mcp/${PQC_KUBELET_MCP} -o yaml
fi

# Wait for MCP to complete update
echo "[INFO] Waiting for Machine Config Pool '${PQC_KUBELET_MCP}' to complete update (max 20 minutes)..."
oc wait mcp/${PQC_KUBELET_MCP} --for condition=Updated=True --timeout=20m

echo "[INFO] Machine Config Pool '${PQC_KUBELET_MCP}' update complete"

# Verify configuration was applied correctly
echo "[INFO] Verifying KubeletConfig..."
current_config=$(oc get kubeletconfig/pqc-tls-config -o json | jq -cS '.spec.tlsSecurityProfile')
desired_config=$(echo "${tls_config}" | jq -cS '.')

if [[ "${current_config}" != "${desired_config}" ]]; then
    echo "[ERROR] KubeletConfig tlsSecurityProfile does not match desired configuration"
    echo "---- Desired:"
    echo "${desired_config}" | jq .
    echo "---- Current:"
    echo "${current_config}" | jq .
    exit 1
fi

echo "[INFO] Kubelet successfully configured with PQC cipher: ${PQC_CIPHER}"
echo "[INFO] Configuration applied to Machine Config Pool: ${PQC_KUBELET_MCP}"
