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
  oc wait --for=jsonpath='{.metadata.name}'=ibm-spectrum-scale cluster/ibm-spectrum-scale -n ibm-spectrum-scale --timeout=1200s
else
  echo "❌ IBM Storage Scale Cluster not found after creation"
  echo "Checking for any clusters in the namespace..."
  oc get clusters -n ibm-spectrum-scale
  exit 1
fi

echo "Labeling worker nodes..."
oc label nodes -l node-role.kubernetes.io/worker "scale.spectrum.ibm.com/role=storage"

echo "✅ Fusion Access deployment completed!"