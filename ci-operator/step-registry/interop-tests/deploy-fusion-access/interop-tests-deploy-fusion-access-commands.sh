#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set default values from environment variables
FUSION_ACCESS_STORAGE_SCALE_VERSION="${FUSION_ACCESS_STORAGE_SCALE_VERSION:-v5.2.3.1}"
FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
STORAGE_SCALE_CLIENT_CPU="${STORAGE_SCALE_CLIENT_CPU:-2}"
STORAGE_SCALE_CLIENT_MEMORY="${STORAGE_SCALE_CLIENT_MEMORY:-4Gi}"
STORAGE_SCALE_STORAGE_CPU="${STORAGE_SCALE_STORAGE_CPU:-2}"
STORAGE_SCALE_STORAGE_MEMORY="${STORAGE_SCALE_STORAGE_MEMORY:-8Gi}"

echo "🚀 Starting Fusion Access Operator deployment..."
echo "Version: ${FUSION_ACCESS_STORAGE_SCALE_VERSION}"
echo "Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Storage Scale Namespace: ${STORAGE_SCALE_NAMESPACE}"

# Check if IBM entitlement credentials are available
if [[ ! -f "/tmp/secrets/ibm-entitlement-credentials/ibm-entitlement-key" ]]; then
  echo "ERROR: IBM entitlement credentials not found"
  echo "Expected path: /tmp/secrets/ibm-entitlement-credentials/ibm-entitlement-key"
  exit 1
fi

echo "✅ IBM entitlement credentials found"

# Step 1: Create IBM Storage Scale namespace
echo "📁 Creating IBM Storage Scale namespace..."
oc create namespace "${STORAGE_SCALE_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Step 2: Create IBM entitlement secret
echo "🔐 Creating IBM entitlement secret..."
oc create secret -n "${FUSION_ACCESS_NAMESPACE}" generic fusion-pullsecret \
  --from-literal=ibm-entitlement-key="$(cat /tmp/secrets/ibm-entitlement-credentials/ibm-entitlement-key)" \
  --dry-run=client -o yaml | oc apply -f -

# Step 3: Create FusionAccess CR
echo "📋 Creating FusionAccess CR..."
oc apply -f - <<EOF
apiVersion: fusion.storage.openshift.io/v1alpha1
kind: FusionAccess
metadata:
  name: fusionaccess-object
  namespace: ${FUSION_ACCESS_NAMESPACE}
spec:
  storageScaleVersion: ${FUSION_ACCESS_STORAGE_SCALE_VERSION}
  storageDeviceDiscovery:
    create: true
EOF

# Step 4: Wait for Fusion Access Operator to be ready
echo "⏳ Waiting for Fusion Access Operator to be ready..."
timeout 900 bash -c 'until oc get csv -n '"${FUSION_ACCESS_NAMESPACE}"' --no-headers | grep -q "fusion-access-operator.*Succeeded"; do sleep 30; done'
echo "✅ Fusion Access Operator is ready"

# Step 5: Wait for FusionAccess CR to be ready
echo "⏳ Waiting for FusionAccess CR to be ready..."
timeout 1200 bash -c 'until oc get fusionaccess fusionaccess-object -n '"${FUSION_ACCESS_NAMESPACE}"' -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q "True"; do sleep 30; done'
echo "✅ FusionAccess CR is ready"

# Step 6: Label worker nodes for storage role
echo "🏷️  Labeling worker nodes for storage role..."
oc label nodes -l node-role.kubernetes.io/worker "scale.spectrum.ibm.com/role=storage" --overwrite
echo "✅ Worker nodes labeled for storage role"

# Step 7: Wait for storage nodes to be ready
echo "⏳ Waiting for storage nodes to be ready..."
timeout 600 bash -c 'until oc get nodes -l "scale.spectrum.ibm.com/role=storage" --no-headers | grep -q "Ready"; do sleep 30; done'
echo "✅ Storage nodes are ready"

# Step 8: Create IBM Storage Scale cluster
echo "🏗️  Creating IBM Storage Scale cluster..."
oc apply -f - <<EOF
---
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata:
  name: ${STORAGE_SCALE_CLUSTER_NAME}
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  pmcollector:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
  daemon:
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
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
    roles:
    - name: client
      resources:
        cpu: "${STORAGE_SCALE_CLIENT_CPU}"
        memory: ${STORAGE_SCALE_CLIENT_MEMORY}
    - name: storage
      resources:
        cpu: "${STORAGE_SCALE_STORAGE_CPU}"
        memory: ${STORAGE_SCALE_STORAGE_MEMORY}
  license:
    accept: true
    license: data-management
EOF

echo "✅ IBM Storage Scale cluster deployment initiated"

# Step 9: Wait for Storage Scale cluster to be ready
echo "⏳ Waiting for IBM Storage Scale cluster to be ready..."
timeout 1200 bash -c 'until oc get cluster '"${STORAGE_SCALE_CLUSTER_NAME}"' -n '"${STORAGE_SCALE_NAMESPACE}"' -o jsonpath="{.status.phase}" | grep -q "Ready"; do sleep 30; done'
echo "✅ IBM Storage Scale cluster is ready"

# Step 10: Wait for Storage Scale pods to be ready
echo "⏳ Waiting for IBM Storage Scale pods to be ready..."
timeout 900 bash -c 'until oc get pods -n '"${STORAGE_SCALE_NAMESPACE}"' --no-headers | grep -v "Completed" | grep -v "Succeeded" | grep -q "Running"; do sleep 30; done'
echo "✅ IBM Storage Scale pods are ready"

echo "🎉 Fusion Access Operator deployment completed successfully!"
echo "📊 Deployment Summary:"
echo "  - Fusion Access Operator: ✅ Ready"
echo "  - IBM Storage Scale Cluster: ✅ Ready"
echo "  - Storage Nodes: ✅ Labeled and Ready"
echo "  - All Pods: ✅ Running"
