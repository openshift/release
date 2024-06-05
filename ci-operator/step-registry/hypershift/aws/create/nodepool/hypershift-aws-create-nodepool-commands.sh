#!/bin/bash

set -exuo pipefail

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$(date) Creating additional NodePool for HyperShift cluster ${CLUSTER_NAME}"
/usr/bin/hypershift create nodepool aws \
  --cluster-name  ${CLUSTER_NAME} \
  --name additional-${CLUSTER_NAME} \
  --node-count ${ADDITIONAL_HYPERSHIFT_NODE_COUNT} \
  --instance-type ${ADDITIONAL_HYPERSHIFT_INSTANCE_TYPE} \
  --arch ${ADDITIONAL_HYPERSHIFT_NODE_ARCH} \
  --release-image ${RELEASE_IMAGE_LATEST}

echo "Wait additional nodepool ready..."
oc wait --timeout=30m nodepool -n clusters additional-${CLUSTER_NAME} --for=condition=Ready
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
echo "Wait HostedCluster ready..."
until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null; do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    oc get clusterversion 2>/dev/null || true
    sleep 10s
done