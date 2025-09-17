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

echo "Verifying CRD details..."
oc get crd clusters.scale.spectrum.ibm.com -o yaml | grep -A 5 -B 5 "validation\|schema" || echo "No validation schema found in CRD"

echo "Checking for any CRD-related events..."
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -i "clusters.scale.spectrum.ibm.com" | tail -5 || echo "No CRD-related events found"

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
  echo "Checking LocalDisk status and conditions..."
  oc get localdisks -n ibm-spectrum-scale -o yaml | grep -A 10 -B 5 "conditions\|status" || echo "No status/conditions found in LocalDisk resources"
else
  echo "⚠️  No LocalDisk resources found in ibm-spectrum-scale namespace"
  echo "This may be expected if the device ${LOCALDISK_DEVICE_PATH} doesn't exist on the nodes"
  echo "Checking for any LocalDisk-related events..."
  oc get events -n ibm-spectrum-scale --sort-by='.lastTimestamp' | grep -i localdisk || echo "No LocalDisk-related events found"
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
    echo "Immediately checking if Cluster resource exists..."
    if oc get cluster ibm-spectrum-scale -n ibm-spectrum-scale 2>/dev/null; then
      echo "✅ Cluster found immediately after creation"
      echo "Getting Cluster details immediately after creation..."
      oc get cluster ibm-spectrum-scale -n ibm-spectrum-scale -o yaml | head -20
    else
      echo "⚠️  Cluster not found immediately after creation"
      echo "Checking for any events related to the Cluster..."
      oc get events -n ibm-spectrum-scale --sort-by='.lastTimestamp' | tail -10
      echo "Checking for any validation errors..."
      oc describe cluster ibm-spectrum-scale -n ibm-spectrum-scale 2>/dev/null || echo "Cannot describe cluster - resource may have been deleted"
    fi
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

echo "Verifying IBM Storage Scale deployment..."
echo "Waiting a moment for the Cluster resource to be fully created..."
sleep 10

echo "Checking if ibm-spectrum-scale namespace exists..."
if oc get namespace ibm-spectrum-scale >/dev/null 2>&1; then
  echo "✅ ibm-spectrum-scale namespace exists"
else
  echo "❌ ibm-spectrum-scale namespace does not exist"
  echo "Creating ibm-spectrum-scale namespace..."
  oc create namespace ibm-spectrum-scale
fi

echo "Checking for IBM Storage Scale Cluster resource..."
if oc get cluster ibm-spectrum-scale -n ibm-spectrum-scale >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale Cluster found, waiting for it to be ready..."
  echo "Waiting for Cluster to have successful condition..."
  oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True cluster/ibm-spectrum-scale -n ibm-spectrum-scale --timeout=1200s
else
  echo "⚠️  IBM Storage Scale Cluster resource not found, but this may be normal if managed by operator"
fi

echo "Checking for IBM Storage Scale pods to verify deployment..."
POD_COUNT=$(oc get pods -n ibm-spectrum-scale --no-headers 2>/dev/null | wc -l)
if [[ $POD_COUNT -gt 0 ]]; then
  echo "✅ Found $POD_COUNT IBM Storage Scale pods:"
  oc get pods -n ibm-spectrum-scale
  echo ""
  echo "Waiting for pods to be ready..."
  oc wait --for=condition=Ready pod -l app.kubernetes.io/name=ibm-spectrum-scale -n ibm-spectrum-scale --timeout=300s || echo "Some pods may still be starting up"
else
  echo "⚠️  No IBM Storage Scale pods found yet"
fi

echo "Checking for IBM Storage Scale daemon resources..."
DAEMON_COUNT=$(oc get daemon -n ibm-spectrum-scale --no-headers 2>/dev/null | wc -l)
if [[ $DAEMON_COUNT -gt 0 ]]; then
  echo "✅ Found $DAEMON_COUNT IBM Storage Scale daemon resources:"
  oc get daemon -n ibm-spectrum-scale
else
  echo "⚠️  No IBM Storage Scale daemon resources found yet"
fi

echo "IBM Storage Scale deployment verification completed."

echo "Creating IBM Storage Scale FileSystem on top of LocalDisk resources..."
if oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: localfilesystem
  namespace: ibm-spectrum-scale
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - shareddisk1
    # Only 1-way is supported for LFS https://www.ibm.com/docs/en/scalecontainernative/5.2.1?topic=systems-local-file-system#filesystem-spec
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
EOF
then
  echo "✅ IBM Storage Scale FileSystem created successfully"
  
  # Verify the FileSystem object was actually created
  echo "Verifying FileSystem object creation..."
  if oc get filesystem localfilesystem -n ibm-spectrum-scale >/dev/null 2>&1; then
    echo "✅ FileSystem object 'localfilesystem' exists in namespace 'ibm-spectrum-scale'"
  else
    echo "❌ FileSystem object 'localfilesystem' not found after creation"
    echo "Checking for any filesystem resources in the namespace..."
    oc get filesystems -n ibm-spectrum-scale
    exit 1
  fi
else
  echo "❌ Failed to create IBM Storage Scale FileSystem"
  echo "This may be expected if the LocalDisk resources are not ready yet"
  exit 1
fi

echo "Waiting for FileSystem to be ready..."
sleep 10

# Wait for FileSystem to be in a ready state
echo "Waiting for FileSystem to reach ready state..."
if oc wait --for=jsonpath='{.status.phase}'=Ready filesystem/localfilesystem -n ibm-spectrum-scale --timeout=300s 2>/dev/null; then
  echo "✅ FileSystem is ready"
else
  echo "⚠️  FileSystem may still be initializing, checking current status..."
  oc get filesystem localfilesystem -n ibm-spectrum-scale -o custom-columns="NAME:.metadata.name,STATUS:.status.phase"
fi

echo "Verifying FileSystem resource status and details..."
if oc get filesystem localfilesystem -n ibm-spectrum-scale >/dev/null 2>&1; then
  echo "✅ FileSystem resource found:"
  oc get filesystem localfilesystem -n ibm-spectrum-scale -o custom-columns="NAME:.metadata.name,STATUS:.status.phase"
  
  # Get detailed FileSystem information
  echo ""
  echo "FileSystem detailed information:"
  oc get filesystem localfilesystem -n ibm-spectrum-scale -o yaml | grep -A 20 "status:"
else
  echo "❌ FileSystem resource not found - this indicates a problem with the creation"
  echo "Checking for any filesystem resources in the namespace..."
  oc get filesystems -n ibm-spectrum-scale
  exit 1
fi

echo "Checking for new StorageClass created by the FileSystem..."
sleep 5
STORAGECLASS_COUNT=$(oc get storageclass --no-headers 2>/dev/null | grep -i spectrum | wc -l)
if [[ $STORAGECLASS_COUNT -gt 0 ]]; then
  echo "✅ Found $STORAGECLASS_COUNT IBM Spectrum Scale StorageClass(es):"
  oc get storageclass | grep -i spectrum
else
  echo "⚠️  No IBM Spectrum Scale StorageClass found yet"
  echo "StorageClass may take some time to be created after FileSystem is ready"
fi

echo "✅ Fusion Access deployment completed!"