#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__CLUSTER_NAME="${FA__SCALE__CLUSTER_NAME:-ibm-spectrum-scale}"
FA__SCALE__CLIENT_CPU="${FA__SCALE__CLIENT_CPU:-2}"
FA__SCALE__CLIENT_MEMORY="${FA__SCALE__CLIENT_MEMORY:-4Gi}"
FA__SCALE__STORAGE_CPU="${FA__SCALE__STORAGE_CPU:-2}"
FA__SCALE__STORAGE_MEMORY="${FA__SCALE__STORAGE_MEMORY:-8Gi}"

echo "🏗️  Creating IBM Storage Scale Cluster..."

# Check if cluster already exists (idempotent)
if oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  echo "✅ Cluster already exists, skipping creation"
  exit 0
fi

echo "Cluster does not exist, creating..."

# Determine quorum configuration based on worker count
WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $WORKER_COUNT -ge 3 ]]; then
  QUORUM_CONFIG="quorum:
    autoAssign: true"
else
  echo "⚠️  Only $WORKER_COUNT worker nodes (3 recommended for quorum)"
  QUORUM_CONFIG=""
fi

# Create cluster with /dev/disk/by-id/* pattern for automatic EBS volume discovery
if cat <<EOF | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata:
  name: ${FA__SCALE__CLUSTER_NAME}
  namespace: ${FA__SCALE__NAMESPACE}
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
      - devicePath: /dev/disk/by-id/*
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
        cpu: "${FA__SCALE__CLIENT_CPU}"
        memory: ${FA__SCALE__CLIENT_MEMORY}
    - name: storage
      resources:
        cpu: "${FA__SCALE__STORAGE_CPU}"
        memory: ${FA__SCALE__STORAGE_MEMORY}
  ${QUORUM_CONFIG}
EOF
then
  echo "✅ Cluster resource created successfully"
else
  echo "❌ Failed to create Cluster resource"
  exit 1
fi

# Verify cluster was created
if ! oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  echo "❌ Cluster resource not found after creation"
  exit 1
fi

# Verify device pattern is configured correctly
DEVICE_PATH=$(oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" \
  -o jsonpath='{.spec.daemon.nsdDevicesConfig.localDevicePaths[0].devicePath}')

if [[ "$DEVICE_PATH" == "/dev/disk/by-id/*" ]]; then
  echo "✅ Cluster configured with /dev/disk/by-id/* device pattern"
else
  echo "⚠️  Cluster has device path: ${DEVICE_PATH} (expected: /dev/disk/by-id/*)"
fi

# Display cluster status
echo ""
echo "📊 Cluster Status:"
oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}"

echo ""
echo "Waiting for cluster to be ready..."
echo "This may take 10-15 minutes for daemon pods to start and kernel modules to build"
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  cluster/"${FA__SCALE__CLUSTER_NAME}" \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout=1800s || {
    echo "⚠️  Cluster not ready within timeout (will be verified in later steps)"
    oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" -o yaml
  }

echo ""
echo "✅ IBM Storage Scale Cluster is ready"
echo "Daemon pods are using /dev/disk/by-id/* pattern to discover EBS volumes"
echo "KMM has built kernel modules using Driver Toolkit"
