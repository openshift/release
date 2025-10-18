#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
STORAGE_SCALE_CLIENT_CPU="${STORAGE_SCALE_CLIENT_CPU:-2}"
STORAGE_SCALE_CLIENT_MEMORY="${STORAGE_SCALE_CLIENT_MEMORY:-4Gi}"
STORAGE_SCALE_STORAGE_CPU="${STORAGE_SCALE_STORAGE_CPU:-2}"
STORAGE_SCALE_STORAGE_MEMORY="${STORAGE_SCALE_STORAGE_MEMORY:-8Gi}"

echo "🏗️  Creating IBM Storage Scale Cluster..."

# Check if cluster already exists (idempotent)
if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ Cluster already exists"
else
  # Determine quorum configuration based on worker count
  WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
  
  if [[ $WORKER_COUNT -ge 3 ]]; then
    QUORUM_CONFIG="quorum:
    autoAssign: true"
  else
    echo "⚠️  Only $WORKER_COUNT worker nodes (3 recommended for quorum)"
    QUORUM_CONFIG=""
  fi
  
  # Create cluster
  cat <<EOF | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata:
  name: ${STORAGE_SCALE_CLUSTER_NAME}
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  license:
    accept: true
    license: data-management
  pmcollector:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
  daemon:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
    nsdDevicesConfig:
      localDevicePaths:
      - devicePath: /dev/nvme2n1
        deviceType: generic
      - devicePath: /dev/nvme3n1
        deviceType: generic
    clusterProfile:
      controlSetxattrImmutableSELinux: "yes"
      enforceFilesetQuotaOnRoot: "yes"
      ignorePrefetchLUNCount: "yes"
      initPrefetchBuffers: "128"
      maxblocksize: 16M
      prefetchPct: "25"
      prefetchTimeout: "30"
    roles:
    - name: client
      resources:
        cpu: "${STORAGE_SCALE_CLIENT_CPU}"
        memory: ${STORAGE_SCALE_CLIENT_MEMORY}
    - name: storage
      resources:
        cpu: "${STORAGE_SCALE_STORAGE_CPU}"
        memory: ${STORAGE_SCALE_STORAGE_MEMORY}
  ${QUORUM_CONFIG}
EOF
  
  echo "✅ Cluster resource created"
fi

oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}"

echo ""
echo "Note: Cluster initialization may take several minutes"
echo "Daemon pods will start and establish quorum"
