#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Configuring KMS encryption for kube-apiserver"
echo "========================================="

# Read socket path from SHARED_DIR
if [ ! -f "${SHARED_DIR}/kms-plugin-socket-path" ]; then
  echo "ERROR: KMS plugin socket path not found in SHARED_DIR"
  echo "Make sure kms-mock-plugin-deploy step ran successfully"
  exit 1
fi

# Read KMS version from SHARED_DIR
if [ ! -f "${SHARED_DIR}/kms-plugin-version" ]; then
  echo "ERROR: KMS plugin version not found in SHARED_DIR"
  echo "Make sure kms-mock-plugin-deploy step ran successfully"
  exit 1
fi

SOCKET_PATH=$(cat "${SHARED_DIR}/kms-plugin-socket-path")
KMS_VERSION=$(cat "${SHARED_DIR}/kms-plugin-version")

echo "Using KMS socket: ${SOCKET_PATH}"
echo "Using KMS version: ${KMS_VERSION}"

# Configure APIServer to use KMS encryption
echo ""
echo "Enabling KMS ${KMS_VERSION} encryption on APIServer..."
oc patch apiserver cluster --type=merge -p '{
  "spec": {
    "encryption": {
      "type": "aescbc"
    }
  }
}'

# Wait a moment for the patch to be processed
sleep 5

# Now switch to KMS - generate config based on version
echo "Switching encryption to KMS ${KMS_VERSION}..."

if [[ "${KMS_VERSION}" == "v1" ]]; then
  # KMSv1 configuration
  cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  encryption:
    type: aescbc
---
apiVersion: v1
kind: Secret
metadata:
  name: kms-config
  namespace: openshift-config
stringData:
  kms-config.yaml: |
    apiVersion: apiserver.config.k8s.io/v1
    kind: EncryptionConfiguration
    resources:
      - resources:
        - secrets
        providers:
        - kms:
            name: mock-kms-plugin
            endpoint: unix://${SOCKET_PATH}
            cachesize: 1000
            timeout: 3s
        - identity: {}
EOF
else
  # KMSv2 configuration
  cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  encryption:
    type: aescbc
---
apiVersion: v1
kind: Secret
metadata:
  name: kms-config
  namespace: openshift-config
stringData:
  kms-config.yaml: |
    apiVersion: apiserver.config.k8s.io/v1
    kind: EncryptionConfiguration
    resources:
      - resources:
        - secrets
        providers:
        - kms:
            apiVersion: v2
            name: mock-kms-plugin
            endpoint: unix://${SOCKET_PATH}
            timeout: 35s
        - identity: {}
EOF
fi

echo ""
echo "Waiting for kube-apiserver encryption to begin..."
echo "This may take up to 30 minutes for encryption migration to complete..."

# Wait for encryption to start
TIMEOUT=1800  # 30 minutes
INTERVAL=30
ELAPSED=0

while [ ${ELAPSED} -lt ${TIMEOUT} ]; do
  # Check encryption status
  ENCRYPTION_STATUS=$(oc get kubeapiserver cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}' 2>/dev/null || echo "NotFound")

  echo "[$(date '+%H:%M:%S')] Encryption status: ${ENCRYPTION_STATUS}"

  if [ "${ENCRYPTION_STATUS}" == "EncryptionCompleted" ]; then
    echo ""
    echo "✓ Encryption migration completed successfully!"
    break
  elif [ "${ENCRYPTION_STATUS}" == "EncryptionInProgress" ] || [ "${ENCRYPTION_STATUS}" == "EncryptionMigrating" ]; then
    echo "  Migration in progress..."
  elif [ "${ENCRYPTION_STATUS}" == "EncryptionFailed" ]; then
    echo "ERROR: Encryption migration failed!"
    oc get kubeapiserver cluster -o yaml
    exit 1
  fi

  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
  echo "ERROR: Encryption migration did not complete within ${TIMEOUT} seconds"
  echo "Current status:"
  oc get kubeapiserver cluster -o yaml
  exit 1
fi

# Wait for cluster to stabilize
echo ""
echo "Waiting for cluster to stabilize after encryption..."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=10m || true

# Verify final status
echo ""
echo "Final encryption status:"
oc get kubeapiserver cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")]}{"\n"}' | jq .

echo ""
echo "========================================="
echo "✓ KMS ${KMS_VERSION} encryption configured successfully!"
echo "  kube-apiserver is now using mock KMS plugin"
echo "  Socket: ${SOCKET_PATH}"
echo "  API Version: ${KMS_VERSION}"
echo "========================================="
