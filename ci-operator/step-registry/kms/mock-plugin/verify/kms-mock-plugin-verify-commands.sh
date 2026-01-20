#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Verifying mock KMS plugin installation"
echo "========================================="

# Read KMS configuration from SHARED_DIR
if [ ! -f "${SHARED_DIR}/kms-plugin-socket-path" ]; then
  echo "ERROR: KMS plugin socket path not found in SHARED_DIR"
  exit 1
fi

if [ ! -f "${SHARED_DIR}/kms-plugin-namespace" ]; then
  echo "ERROR: KMS plugin namespace not found in SHARED_DIR"
  exit 1
fi

if [ ! -f "${SHARED_DIR}/kms-plugin-version" ]; then
  echo "ERROR: KMS plugin version not found in SHARED_DIR"
  exit 1
fi

KMS_SOCKET=$(cat "${SHARED_DIR}/kms-plugin-socket-path")
KMS_NAMESPACE=$(cat "${SHARED_DIR}/kms-plugin-namespace")
KMS_VERSION=$(cat "${SHARED_DIR}/kms-plugin-version")

echo "KMS Socket: ${KMS_SOCKET}"
echo "KMS Namespace: ${KMS_NAMESPACE}"
echo "KMS Version: ${KMS_VERSION}"
echo ""

# Verify KMS plugin pods are running
echo "Checking KMS plugin pods..."
oc get pods -n "${KMS_NAMESPACE}" -l app=kms-plugin -o wide

POD_COUNT=$(oc get pods -n "${KMS_NAMESPACE}" -l app=kms-plugin --field-selector=status.phase=Running -o name | wc -l)
echo "Running KMS plugin pods: ${POD_COUNT}"

if [ "${POD_COUNT}" -eq 0 ]; then
  echo "ERROR: No running KMS plugin pods found"
  oc describe pods -n "${KMS_NAMESPACE}" -l app=kms-plugin
  exit 1
fi

# Get all control plane nodes
CONTROL_PLANE_NODES=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}')
NODE_COUNT=$(echo ${CONTROL_PLANE_NODES} | wc -w)
echo ""
echo "Control plane nodes (${NODE_COUNT}):"
for node in ${CONTROL_PLANE_NODES}; do
  echo "  - ${node}"
done

# Verify KMS plugin is running on each control plane node
echo ""
echo "Verifying KMS plugin on each control plane node..."
VERIFIED_COUNT=0

for node in ${CONTROL_PLANE_NODES}; do
  echo ""
  echo "========================================="
  echo "Checking node: ${node}"
  echo "========================================="

  # Get pod running on this node
  POD=$(oc get pods -n "${KMS_NAMESPACE}" -l app=kms-plugin --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')

  if [ -z "${POD}" ]; then
    echo "  ERROR: No KMS plugin pod found on node ${node}"
    exit 1
  fi

  echo "  Pod: ${POD}"

  # Check pod status
  POD_STATUS=$(oc get pod -n "${KMS_NAMESPACE}" "${POD}" -o jsonpath='{.status.phase}')
  echo "  Status: ${POD_STATUS}"

  if [ "${POD_STATUS}" != "Running" ]; then
    echo "  ERROR: Pod is not running"
    oc describe pod -n "${KMS_NAMESPACE}" "${POD}"
    oc logs -n "${KMS_NAMESPACE}" "${POD}" --all-containers || true
    exit 1
  fi

  # Verify socket exists
  echo "  Checking socket at ${KMS_SOCKET}..."
  if oc exec -n "${KMS_NAMESPACE}" "${POD}" -- test -S "${KMS_SOCKET}"; then
    echo "  ✓ Socket verified"
  else
    echo "  ERROR: Socket not found at ${KMS_SOCKET}"
    oc exec -n "${KMS_NAMESPACE}" "${POD}" -- ls -la /var/run/kmsplugin/ || true
    exit 1
  fi

  # Check for errors in logs
  echo "  Checking logs for errors..."
  ERROR_COUNT=$(oc logs -n "${KMS_NAMESPACE}" "${POD}" --tail=100 | grep -i error | wc -l || true)
  if [ "${ERROR_COUNT}" -gt 0 ]; then
    echo "  WARNING: Found ${ERROR_COUNT} error(s) in logs"
    oc logs -n "${KMS_NAMESPACE}" "${POD}" --tail=100 | grep -i error || true
  else
    echo "  ✓ No errors in recent logs"
  fi

  # Show recent logs
  echo "  Recent logs (last 10 lines):"
  oc logs -n "${KMS_NAMESPACE}" "${POD}" --tail=10 | sed 's/^/    /'

  VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
  echo "  ✓ Node ${node} verification passed"
done

echo ""
echo "========================================="
echo "KMS Plugin Pod Verification Summary"
echo "========================================="
echo "Control plane nodes: ${NODE_COUNT}"
echo "Verified nodes: ${VERIFIED_COUNT}"

if [ "${NODE_COUNT}" -ne "${VERIFIED_COUNT}" ]; then
  echo "ERROR: Not all control plane nodes have KMS plugin running"
  exit 1
fi

# Verify encryption status (if encryption was configured)
if oc get kubeapiserver cluster &>/dev/null; then
  echo ""
  echo "Checking kube-apiserver encryption status..."
  ENCRYPTION_STATUS=$(oc get kubeapiserver cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}' 2>/dev/null || echo "NotConfigured")
  echo "Encryption status: ${ENCRYPTION_STATUS}"

  if [ "${ENCRYPTION_STATUS}" == "EncryptionCompleted" ]; then
    echo "✓ Encryption is active and completed"
  elif [ "${ENCRYPTION_STATUS}" == "EncryptionInProgress" ]; then
    echo "⚠ Encryption migration is in progress"
  elif [ "${ENCRYPTION_STATUS}" == "NotConfigured" ]; then
    echo "ℹ Encryption not yet configured (this is OK if configure step hasn't run)"
  else
    echo "⚠ Unexpected encryption status: ${ENCRYPTION_STATUS}"
  fi
fi

echo ""
echo "========================================="
echo "✓ Mock KMS ${KMS_VERSION} plugin verification successful!"
echo "  All ${VERIFIED_COUNT} control plane nodes verified"
echo "  Socket: ${KMS_SOCKET}"
echo "  Namespace: ${KMS_NAMESPACE}"
echo "========================================="
