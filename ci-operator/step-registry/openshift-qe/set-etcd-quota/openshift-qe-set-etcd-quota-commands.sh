#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ETCD_QUOTA_BACKEND_GIB="${ETCD_QUOTA_BACKEND_GIB:-8}"

# Calculate bytes from GiB (1 GiB = 1073741824 bytes = 1024^3)
QUOTA_BYTES=$((ETCD_QUOTA_BACKEND_GIB * 1073741824))

echo "Setting etcd backend quota to ${ETCD_QUOTA_BACKEND_GIB} GiB (${QUOTA_BYTES} bytes)..."

# Patch etcd cluster with backendQuotaGiB
oc patch etcd/cluster --type=merge -p "{\"spec\": {\"backendQuotaGiB\": ${ETCD_QUOTA_BACKEND_GIB}}}"

echo "Waiting for etcd operator to start rollout..."
if ! oc wait --timeout=2m --for=condition=Progressing=true co/etcd 2>/dev/null; then
  echo "Warning: etcd operator did not enter Progressing state, continuing..."
fi

echo "Waiting for etcd operator rollout to complete..."
if ! oc wait --timeout=30m --for=condition=Progressing=false co/etcd; then
  echo "Error: etcd operator rollout failed (Progressing timeout)"
  exit 1
fi

if ! oc wait --timeout=2m --for=condition=Degraded=false co/etcd; then
  echo "Error: etcd operator is degraded after rollout"
  exit 1
fi

if ! oc wait --timeout=2m --for=condition=Available=true co/etcd; then
  echo "Error: etcd operator is not available after rollout"
  exit 1
fi

echo "Waiting for all etcd pods to be ready..."
expected_pods=$(oc get nodes -l node-role.kubernetes.io/master= --no-headers | wc -l)
ready_pods=0
retry_count=0
max_retries=60

while [ "$ready_pods" -lt "$expected_pods" ]; do
  if [ "$retry_count" -ge "$max_retries" ]; then
    echo "Error: Timeout waiting for etcd pods to be ready"
    oc get pods -n openshift-etcd -l app=etcd
    exit 1
  fi

  ready_pods=$(oc get pods -n openshift-etcd -l app=etcd --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  echo "etcd pods ready: ${ready_pods}/${expected_pods}"

  if [ "$ready_pods" -lt "$expected_pods" ]; then
    sleep 5
    retry_count=$((retry_count + 1))
  fi
done

echo "Describing etcd/cluster"
oc describe etcd/cluster
echo "Logging etcd pods env"
oc describe -n openshift-etcd pod/etcd-ip-10 | grep -C1 "ETCD_QUOTA_BACKEND_BYTES"

echo "✅ Successfully configured etcd backend quota to ${ETCD_QUOTA_BACKEND_GIB} GiB"
echo "All ${expected_pods} etcd pods are ready"
