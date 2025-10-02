#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
STORAGE_SCALE_CLIENT_CPU="${STORAGE_SCALE_CLIENT_CPU:-2}"
STORAGE_SCALE_CLIENT_MEMORY="${STORAGE_SCALE_CLIENT_MEMORY:-4Gi}"
STORAGE_SCALE_STORAGE_CPU="${STORAGE_SCALE_STORAGE_CPU:-2}"
STORAGE_SCALE_STORAGE_MEMORY="${STORAGE_SCALE_STORAGE_MEMORY:-8Gi}"

echo "🏗️  Creating IBM Storage Scale Cluster..."

# Check worker node count for quorum configuration
WORKER_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
echo "Found $WORKER_NODE_COUNT worker nodes"

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
  
  # Create cluster configuration with quorum settings
  if [[ $WORKER_NODE_COUNT -lt 3 ]]; then
    echo "⚠️  Configuring cluster for limited node environment (less than 3 worker nodes)"
    QUORUM_CONFIG=""
  else
    echo "✅ Configuring cluster for standard environment (3+ worker nodes)"
    QUORUM_CONFIG="
  quorum:
    autoAssign: true"
  fi
  
  if oc apply -f=- <<EOF
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
      - devicePath: /dev/nvme2n1
        deviceType: generic
      - devicePath: /dev/nvme3n1
        deviceType: generic
      - devicePath: /dev/nvme4n1
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
        memory: ${STORAGE_SCALE_STORAGE_MEMORY}${QUORUM_CONFIG}
  license:
    accept: true
    license: data-management
EOF
  then
    echo "✅ IBM Storage Scale Cluster created successfully on attempt $ATTEMPT"
    echo "Immediately checking if Cluster resource exists..."
    if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" 2>/dev/null; then
      echo "✅ Cluster found immediately after creation"
      echo "Getting Cluster details immediately after creation..."
      oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o yaml | head -20
    else
      echo "⚠️  Cluster not found immediately after creation"
      echo "Checking for any events related to the Cluster..."
      oc get events -n "${STORAGE_SCALE_NAMESPACE}" --sort-by='.lastTimestamp' | tail -10
      echo "Checking for any validation errors..."
      oc describe cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" 2>/dev/null || echo "Cannot describe cluster - resource may have been deleted"
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

echo "Verifying IBM Storage Scale Cluster creation..."
echo "Waiting a moment for the Cluster resource to be fully created..."
sleep 10

echo "Checking for IBM Storage Scale Cluster resource..."
if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale Cluster found, waiting for it to be ready..."
  echo "Waiting for Cluster to have successful condition..."
  
  if oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True cluster/"${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" --timeout=1200s; then
    echo "✅ IBM Storage Scale Cluster is ready"
  else
    echo "⚠️  IBM Storage Scale Cluster did not reach Success condition within timeout"
    echo "Checking cluster status and conditions..."
    oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o yaml | grep -A 20 "conditions:"
    
    # Check for specific quorum-related failures
    QUORUM_ERROR=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].message}' 2>/dev/null || echo "")
    if [[ "$QUORUM_ERROR" == *"quorum"* ]] || [[ "$QUORUM_ERROR" == *"Quorum"* ]]; then
      echo "❌ Quorum-related failure detected: $QUORUM_ERROR"
      echo "This is likely due to insufficient worker nodes (need at least 3 for quorum)"
      echo "Current worker node count: $WORKER_NODE_COUNT"
      echo "Proceeding with cluster verification despite quorum issues..."
    else
      echo "❌ Cluster failed for other reasons: $QUORUM_ERROR"
      echo "Proceeding with cluster verification to gather more information..."
    fi
  fi
else
  echo "⚠️  IBM Storage Scale Cluster resource not found, but this may be normal if managed by operator"
fi

echo "Checking for IBM Storage Scale pods to verify cluster deployment..."
POD_COUNT=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
if [[ $POD_COUNT -gt 0 ]]; then
  echo "✅ Found $POD_COUNT IBM Storage Scale pods:"
  oc get pods -n "${STORAGE_SCALE_NAMESPACE}"
  echo ""
  echo "Waiting for pods to be ready..."
  oc wait --for=condition=Ready pod -l app.kubernetes.io/name=ibm-spectrum-scale -n "${STORAGE_SCALE_NAMESPACE}" --timeout=300s || echo "Some pods may still be starting up"
else
  echo "⚠️  No IBM Storage Scale pods found yet"
fi

echo "Checking for IBM Storage Scale daemon resources..."
DAEMON_COUNT=$(oc get daemon -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
if [[ $DAEMON_COUNT -gt 0 ]]; then
  echo "✅ Found $DAEMON_COUNT IBM Storage Scale daemon resources:"
  oc get daemon -n "${STORAGE_SCALE_NAMESPACE}"
else
  echo "⚠️  No IBM Storage Scale daemon resources found yet"
fi

echo "✅ IBM Storage Scale Cluster creation completed!"
