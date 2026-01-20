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

echo "[INFO] Configuring Ingress Controller with PQC TLS profile:"
echo "${tls_config}" | jq .

# Apply the configuration
echo "[INFO] Patching ingresscontroller/default in openshift-ingress-operator namespace..."
oc patch ingresscontroller/default \
  -n openshift-ingress-operator \
  --type=merge \
  -p "{\"spec\": {\"tlsSecurityProfile\": ${tls_config}}}"

# Wait for ingress operator to start reconciling
echo "[INFO] Waiting for Ingress Operator to start reconciling..."
sleep 5

# Wait for ingress operator to finish reconciliation (max 10 minutes)
echo "[INFO] Waiting for Ingress Operator to complete reconciliation..."
timeout=600
interval=10
elapsed=0

while [ ${elapsed} -lt ${timeout} ]; do
    # Check if operator is available, not progressing, and not degraded
    available=$(oc get co ingress -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
    progressing=$(oc get co ingress -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')
    degraded=$(oc get co ingress -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')

    if [[ "${available}" == "True" && "${progressing}" == "False" && "${degraded}" == "False" ]]; then
        echo "[INFO] Ingress Operator reconciliation complete"
        break
    fi

    echo "[INFO] Waiting for operator (Available=${available}, Progressing=${progressing}, Degraded=${degraded})..."
    sleep ${interval}
    elapsed=$((elapsed + interval))
done

if [ ${elapsed} -ge ${timeout} ]; then
    echo "[ERROR] Timed out waiting for Ingress Operator to reconcile"
    echo "[INFO] Current cluster operator status:"
    oc get co ingress -o yaml
    exit 1
fi

# Verify configuration was applied correctly
echo "[INFO] Verifying configuration..."
current_config=$(oc get ingresscontroller/default -n openshift-ingress-operator -o json | jq -cS '.spec.tlsSecurityProfile')
desired_config=$(echo "${tls_config}" | jq -cS '.')

if [[ "${current_config}" != "${desired_config}" ]]; then
    echo "[ERROR] Ingress Controller tlsSecurityProfile does not match desired configuration"
    echo "---- Desired:"
    echo "${desired_config}" | jq .
    echo "---- Current:"
    echo "${current_config}" | jq .
    exit 1
fi

echo "[INFO] Ingress Controller successfully configured with PQC cipher: ${PQC_CIPHER}"
