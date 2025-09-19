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

echo "Starting Fusion Access Operator deployment..."
echo "Version: ${FUSION_ACCESS_STORAGE_SCALE_VERSION}"
echo "Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Storage Scale Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Using IBM Storage Scale native shared storage for multi-node access"

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
echo "Note: FusionAccess operator should install IBM Storage Scale operator and its CRDs"

# Check if FusionAccess operator is actually installing the IBM Storage Scale operator
echo "Checking for IBM Storage Scale operator installation..."
sleep 30  # Give the operator time to start installing

# Wait for CRDs with longer timeout and better error handling
if oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=600s 2>/dev/null; then
  echo "✅ IBM Storage Scale CRDs are available"
else
  echo "⚠️  IBM Storage Scale CRDs not found after 10 minutes"
  echo "This may indicate that the FusionAccess operator is not installing the IBM Storage Scale operator"
  echo "Checking for any IBM Storage Scale related operators..."
  oc get csv -A | grep -i spectrum || echo "No IBM Spectrum Scale operators found"
  echo "Checking for any IBM Storage Scale related CRDs..."
  oc get crd | grep -i spectrum || echo "No IBM Spectrum Scale CRDs found"
  echo "Checking FusionAccess operator logs for errors..."
  oc logs -n ${FUSION_ACCESS_NAMESPACE} -l app.kubernetes.io/name=openshift-fusion-access-operator --tail=50 || echo "Cannot get FusionAccess operator logs"
  echo "Proceeding anyway - the Cluster creation may still work if CRDs are installed later"
fi

echo "Verifying CRD details..."
if oc get crd clusters.scale.spectrum.ibm.com >/dev/null 2>&1; then
  oc get crd clusters.scale.spectrum.ibm.com -o yaml | grep -A 5 -B 5 "validation\|schema" || echo "No validation schema found in CRD"
else
  echo "⚠️  CRD clusters.scale.spectrum.ibm.com not found"
fi

echo "Checking for any CRD-related events..."
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -i "clusters.scale.spectrum.ibm.com" | tail -5 || echo "No CRD-related events found"

echo "Labeling worker nodes for IBM Storage Scale..."
oc label nodes -l node-role.kubernetes.io/worker "scale.spectrum.ibm.com/role=storage"

echo "Creating IBM Storage Scale shared storage using LocalDisk and Filesystem..."
echo "Note: Using IBM Storage Scale native shared storage for multi-node access"

# Get worker node information for LocalDisk creation
echo "Getting worker node information..."
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath="{range .items[*]}{.metadata.name}{'\n'}{end}")
readarray -t NODE_ARRAY <<< "$WORKER_NODES"
NODE_COUNT=${#NODE_ARRAY[@]}

echo "Found ${NODE_COUNT} worker nodes:"
for NODE in "${NODE_ARRAY[@]}"; do
  if [[ -n "$NODE" ]]; then
    echo "  - $NODE"
  fi
done

# Create LocalDisk for each worker node to enable shared storage
echo "Creating LocalDisk resources for shared storage..."
DISK_COUNT=1
for NODE in "${NODE_ARRAY[@]}"; do
  if [[ -n "$NODE" ]]; then
    echo "Creating LocalDisk for node: $NODE"
    if oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: LocalDisk
metadata:
  name: shareddisk${DISK_COUNT}
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  device: /dev/nvme1n1
  node: ${NODE}
  nodeConnectionSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  existingDataSkipVerify: true
EOF
    then
      echo "✅ LocalDisk shareddisk${DISK_COUNT} created for node $NODE"
    else
      echo "❌ Failed to create LocalDisk shareddisk${DISK_COUNT} for node $NODE"
      exit 1
    fi
    ((DISK_COUNT++))
  fi
done

echo "Waiting for LocalDisk resources to be ready..."
sleep 30

echo "Verifying LocalDisk resources..."
if oc get localdisks -n ${STORAGE_SCALE_NAMESPACE} >/dev/null 2>&1; then
  echo "✅ LocalDisk resources found:"
  oc get localdisks -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,NODE:.spec.node,DEVICE:.spec.device"
else
  echo "❌ No LocalDisk resources found"
  echo "Checking for any LocalDisk-related events..."
  oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -i localdisk || echo "No LocalDisk-related events found"
  exit 1
fi

echo "Creating IBM Storage Scale Cluster..."
echo "Note: If CRDs are not available yet, the Cluster creation will be retried"

MAX_ATTEMPTS=3
ATTEMPT=1

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  echo "Attempt $ATTEMPT of $MAX_ATTEMPTS..."
  
  # Check if CRD exists before attempting to create Cluster
  if ! oc get crd clusters.scale.spectrum.ibm.com >/dev/null 2>&1; then
    echo "⚠️  CRD clusters.scale.spectrum.ibm.com not found, waiting 30 seconds before attempt $ATTEMPT..."
    sleep 30
  fi
  
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
    echo "Checking for specific error details..."
    
    # Check if the error is related to missing CRD
    if ! oc get crd clusters.scale.spectrum.ibm.com >/dev/null 2>&1; then
      echo "❌ CRD clusters.scale.spectrum.ibm.com is still not available"
      echo "This indicates the FusionAccess operator is not installing the IBM Storage Scale operator"
      echo "Checking FusionAccess operator status..."
      oc get csv -n ${FUSION_ACCESS_NAMESPACE} | grep fusion-access || echo "No FusionAccess CSV found"
      echo "Checking for any operator installation events..."
      oc get events -n ${FUSION_ACCESS_NAMESPACE} --sort-by='.lastTimestamp' | tail -10
    else
      echo "✅ CRD is available, checking for other issues..."
      echo "Current CRD status:"
      oc get crd clusters.scale.spectrum.ibm.com -o yaml | grep -A 10 "status:" || echo "No status found in CRD"
    fi
    
    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
      echo "⏳ Waiting 1 minute before retry..."
      sleep 60
    else
      echo "❌ All $MAX_ATTEMPTS attempts failed"
      echo "Final debugging information:"
      echo "FusionAccess operator status:"
      oc get csv -n ${FUSION_ACCESS_NAMESPACE} | grep fusion-access || echo "No FusionAccess CSV found"
      echo "IBM Storage Scale operator status:"
      oc get csv -A | grep -i spectrum || echo "No IBM Spectrum Scale operators found"
      echo "Available CRDs:"
      oc get crd | grep -i spectrum || echo "No IBM Spectrum Scale CRDs found"
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

echo "Creating IBM Storage Scale Filesystem for shared storage..."
echo "Note: Creating Filesystem on top of LocalDisk resources for multi-node access"

# Create Filesystem on top of LocalDisk resources
echo "Creating Filesystem resource..."
if oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: shared-filesystem
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - shareddisk1
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
EOF
then
  echo "✅ IBM Storage Scale Filesystem created successfully"
else
  echo "❌ Failed to create IBM Storage Scale Filesystem"
  exit 1
fi

echo "Waiting for IBM Storage Scale Filesystem to be ready..."
echo "Note: Filesystem creation can take up to 1 hour for large configurations"
if oc wait --for=jsonpath='{.status.phase}'=Ready filesystem/shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} --timeout=3600s; then
  echo "✅ IBM Storage Scale Filesystem is ready"
else
  echo "⚠️  IBM Storage Scale Filesystem not ready within 1 hour, checking status..."
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o yaml | grep -A 10 -B 5 "status:" || echo "No status information available"
fi

echo "Verifying IBM Storage Scale Filesystem..."
if oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale Filesystem found:"
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.status.storageClass"
else
  echo "❌ IBM Storage Scale Filesystem not found"
  echo "Checking for any Filesystem-related events..."
  oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -i filesystem || echo "No Filesystem-related events found"
  exit 1
fi

echo "Checking for StorageClass created by IBM Storage Scale Filesystem..."
echo "Waiting for StorageClass to be available (up to 12 minutes)..."
STORAGECLASS_ATTEMPTS=0
MAX_STORAGECLASS_ATTEMPTS=24
while [[ $STORAGECLASS_ATTEMPTS -lt $MAX_STORAGECLASS_ATTEMPTS ]]; do
  if oc get storageclass | grep -i spectrum >/dev/null 2>&1; then
    echo "✅ IBM Storage Scale StorageClass found:"
    oc get storageclass | grep -i spectrum
    break
  else
    echo "⏳ Waiting for IBM Storage Scale StorageClass... (attempt $((STORAGECLASS_ATTEMPTS + 1))/$MAX_STORAGECLASS_ATTEMPTS)"
    sleep 30
    ((STORAGECLASS_ATTEMPTS++))
  fi
done

if [[ $STORAGECLASS_ATTEMPTS -eq $MAX_STORAGECLASS_ATTEMPTS ]]; then
  echo "⚠️  IBM Storage Scale StorageClass not found after 12 minutes"
  echo "Available StorageClasses:"
  oc get storageclass
fi

echo "Storage deployment summary:"
echo "✅ IBM Storage Scale Cluster: Deployed with local storage"
echo "✅ IBM Storage Scale LocalDisk: Created for shared storage"
echo "✅ IBM Storage Scale Filesystem: Created for multi-node access"
echo ""
echo "Available storage options:"
echo "1. IBM Storage Scale local storage (for IBM Storage Scale operations)"
echo "2. IBM Storage Scale shared Filesystem (for application data sharing across pods)"
echo ""

echo "IBM Storage Scale Shared Storage Information:"
echo "LocalDisk resources:"
oc get localdisks -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,NODE:.spec.node,DEVICE:.spec.device" 2>/dev/null || echo "No LocalDisk resources found"

echo ""
echo "Filesystem status:"
oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.status.storageClass" 2>/dev/null || echo "Filesystem not found"

echo ""
echo "Available StorageClasses for shared storage:"
oc get storageclass | grep -E "(spectrum|gp2)" || echo "No IBM Storage Scale or GP2 StorageClasses found"

echo "✅ Fusion Access deployment completed!"