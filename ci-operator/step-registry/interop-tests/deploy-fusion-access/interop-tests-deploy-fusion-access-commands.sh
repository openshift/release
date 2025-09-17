#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_STORAGE_SCALE_VERSION="${FUSION_ACCESS_STORAGE_SCALE_VERSION:-v5.2.3.1}"
FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
STORAGE_SCALE_CLIENT_CPU="${STORAGE_SCALE_CLIENT_CPU:-2}"
STORAGE_SCALE_CLIENT_MEMORY="${STORAGE_SCALE_CLIENT_MEMORY:-4Gi}"
STORAGE_SCALE_STORAGE_CPU="${STORAGE_SCALE_STORAGE_CPU:-2}"
STORAGE_SCALE_STORAGE_MEMORY="${STORAGE_SCALE_STORAGE_MEMORY:-8Gi}"
LOCALDISK_DEVICE_PATH="${LOCALDISK_DEVICE_PATH:-/dev/nvme1n1}"

echo "Starting Fusion Access Operator deployment..."
echo "Version: ${FUSION_ACCESS_STORAGE_SCALE_VERSION}"
echo "Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Storage Scale Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "LocalDisk Device Path: ${LOCALDISK_DEVICE_PATH}"

IBM_ENTITLEMENT_KEY="$(cat "/var/run/secrets/ibm-entitlement-key")"
FUSION_PULL_SECRET_EXTRA="$(cat "/var/run/secrets/fusion-pullsecret-extra")"

if oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} already exists"
else
  echo "Creating namespace ${FUSION_ACCESS_NAMESPACE}..."
  oc create namespace "${FUSION_ACCESS_NAMESPACE}"
fi

echo "Waiting for namespace to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Active namespace/${FUSION_ACCESS_NAMESPACE} --timeout=60s

echo "Creating fusion-pullsecret..."
oc create secret -n "${FUSION_ACCESS_NAMESPACE}" generic fusion-pullsecret --from-literal=ibm-entitlement-key="${IBM_ENTITLEMENT_KEY}" --dry-run=client -o yaml | oc apply -f -

echo "Waiting for fusion-pullsecret to be ready..."
oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret secret/fusion-pullsecret -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s

echo "Creating fusion-pullsecret-extra..."
oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret-extra
  namespace: ${FUSION_ACCESS_NAMESPACE}
stringData:
  .dockerconfigjson: |
    {
      "quay.io/openshift-storage-scale": {
        "auth": "${FUSION_PULL_SECRET_EXTRA}",
        "email": ""
      }
    }
type: kubernetes.io/dockerconfigjson
EOF

echo "Waiting for fusion-pullsecret-extra to be ready..."
oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret-extra secret/fusion-pullsecret-extra -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s

echo "Creating FusionAccess resource..."
oc apply -f=- <<EOF
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

echo "Waiting for FusionAccess to be ready..."
oc wait --for=jsonpath='{.metadata.name}'=fusionaccess-object fusionaccess/fusionaccess-object -n ${FUSION_ACCESS_NAMESPACE} --timeout=600s

echo "Waiting for IBM Storage Scale CRDs to be available..."
oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=300s

echo "Labeling worker nodes for IBM Storage Scale..."
oc label nodes -l node-role.kubernetes.io/worker "scale.spectrum.ibm.com/role=storage"

echo "Creating IBM Storage Scale LocalDisk for shared storage..."
echo "Getting worker node information..."
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath="{range .items[*]}{.metadata.name}{'\n'}{end}")
if [[ -z "$WORKER_NODES" ]]; then
  echo "❌ No worker nodes found"
  exit 1
fi

echo "Worker nodes found:"
echo "$WORKER_NODES"

# Convert worker nodes to array for processing
readarray -t NODE_ARRAY <<< "$WORKER_NODES"
NODE_COUNT=${#NODE_ARRAY[@]}
echo "Total worker nodes: $NODE_COUNT"

# Create LocalDisk for each worker node to ensure shared access
DISK_COUNT=1
for NODE in "${NODE_ARRAY[@]}"; do
  if [[ -n "$NODE" ]]; then
    echo "Creating LocalDisk for node: $NODE"
    
    if oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: LocalDisk
metadata:
  name: shareddisk${DISK_COUNT}
  namespace: ibm-spectrum-scale
spec:
  # Use configurable device path
  device: ${LOCALDISK_DEVICE_PATH}
  # The Kubernetes node where the specified device exists at creation time
  node: ${NODE}
  # nodeConnectionSelector defines the nodes that have the shared lun directly attached to them
  nodeConnectionSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  # Set below only during testing, this will wipe existing stuff
  existingDataSkipVerify: true
EOF
    then
      echo "✅ LocalDisk shareddisk${DISK_COUNT} created successfully for node $NODE"
    else
      echo "❌ Failed to create LocalDisk shareddisk${DISK_COUNT} for node $NODE"
    fi
    
    ((DISK_COUNT++))
  fi
done

echo "Created $((DISK_COUNT-1)) LocalDisk resources for shared storage across all worker nodes"

echo "Verifying LocalDisk resources..."
LOCALDISK_COUNT=$(oc get localdisks -n ibm-spectrum-scale --no-headers 2>/dev/null | wc -l)
if [[ $LOCALDISK_COUNT -gt 0 ]]; then
  echo "✅ Found $LOCALDISK_COUNT LocalDisk resources in ibm-spectrum-scale namespace:"
  oc get localdisks -n ibm-spectrum-scale -o custom-columns="NAME:.metadata.name,NODE:.spec.node,DEVICE:.spec.device"
else
  echo "⚠️  No LocalDisk resources found in ibm-spectrum-scale namespace"
  echo "This may be expected if the device ${LOCALDISK_DEVICE_PATH} doesn't exist on the nodes"
fi

echo "Creating IBM Storage Scale Cluster..."
MAX_ATTEMPTS=3
ATTEMPT=1

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  echo "Attempt $ATTEMPT of $MAX_ATTEMPTS..."
  
  if oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata:
  name: ibm-spectrum-scale
  namespace: ibm-spectrum-scale
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
  then
    echo "✅ IBM Storage Scale Cluster created successfully on attempt $ATTEMPT"
    break
  else
    echo "❌ Failed to create IBM Storage Scale Cluster on attempt $ATTEMPT"
    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
      echo "⏳ Waiting 1 minute before retry..."
      sleep 60
    else
      echo "❌ All $MAX_ATTEMPTS attempts failed"
      exit 1
    fi
  fi
  
  ((ATTEMPT++))
done

echo "Verifying IBM Storage Scale Cluster exists..."
if oc get cluster ibm-spectrum-scale -n ibm-spectrum-scale >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale Cluster found, waiting for it to be ready..."
  echo "Waiting for Cluster to have successful condition..."
  oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True cluster/ibm-spectrum-scale -n ibm-spectrum-scale --timeout=1200s
else
  echo "❌ IBM Storage Scale Cluster not found after creation"
  echo "Checking for any clusters in the namespace..."
  oc get clusters -n ibm-spectrum-scale
  exit 1
fi

echo "✅ Fusion Access deployment completed!"