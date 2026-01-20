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

echo "[INFO] Configuring API server with PQC TLS profile:"
echo "${tls_config}" | jq .

# Apply the configuration
echo "[INFO] Patching apiserver/cluster..."
oc patch apiserver/cluster --type=merge -p "{\"spec\": {\"tlsSecurityProfile\": ${tls_config}}}"

# Wait for cluster to stabilize
echo "[INFO] Waiting for cluster to stabilize (minimum 1 minute, timeout 15 minutes)..."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=15m

# Verify configuration was applied correctly
echo "[INFO] Verifying configuration..."
current_config=$(oc get apiserver/cluster -o json | jq -cS '.spec.tlsSecurityProfile')
desired_config=$(echo "${tls_config}" | jq -cS '.')

if [[ "${current_config}" != "${desired_config}" ]]; then
    echo "[ERROR] API server tlsSecurityProfile does not match desired configuration"
    echo "---- Desired:"
    echo "${desired_config}" | jq .
    echo "---- Current:"
    echo "${current_config}" | jq .
    exit 1
fi

echo "[INFO] API server successfully configured with PQC cipher: ${PQC_CIPHER}"

# Save cipher configuration for reference by other steps
echo "${PQC_CIPHER}" > "${SHARED_DIR}/pqc-cipher.txt"
echo "[INFO] Saved cipher configuration to ${SHARED_DIR}/pqc-cipher.txt"
