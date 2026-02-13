#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__CLUSTER_NAME="${FA__SCALE__CLUSTER_NAME:-ibm-spectrum-scale}"
FA__SCALE__CLIENT_CPU="${FA__SCALE__CLIENT_CPU:-2}"
FA__SCALE__CLIENT_MEMORY="${FA__SCALE__CLIENT_MEMORY:-4Gi}"
FA__SCALE__STORAGE_CPU="${FA__SCALE__STORAGE_CPU:-2}"
FA__SCALE__STORAGE_MEMORY="${FA__SCALE__STORAGE_MEMORY:-8Gi}"

: 'Creating IBM Storage Scale Cluster'

# Check if cluster already exists (idempotent)
if oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  : '✅ Cluster already exists, skipping creation'
  exit 0
fi

# Determine quorum configuration based on worker count
workerCount=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $workerCount -ge 3 ]]; then
  quorumConfig="quorum:
    autoAssign: true"
else
  quorumConfig=""
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
  ${quorumConfig}
EOF
then
  : '✅ Cluster resource created successfully'
else
  : '❌ Failed to create Cluster resource'
  exit 1
fi

# Verify cluster was created
if ! oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  : '❌ Cluster resource not found after creation'
  exit 1
fi

# Verify device pattern is configured correctly
devicePath=$(oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" \
  -o jsonpath='{.spec.daemon.nsdDevicesConfig.localDevicePaths[0].devicePath}')

if [[ "$devicePath" == "/dev/disk/by-id/*" ]]; then
  : '✅ Cluster configured with /dev/disk/by-id/* device pattern'
fi

oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}"

: 'Waiting for cluster to be ready (may take 10-15 minutes)'
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  cluster/"${FA__SCALE__CLUSTER_NAME}" \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout=1800s

: '✅ IBM Storage Scale Cluster is ready'

