#!/bin/bash

set -exuo pipefail

# Ensure that oc commands run against the management cluster by default
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$(date) Creating additional NodePool for HyperShift cluster ${CLUSTER_NAME}"

# Set nodepool render yaml file according ${NODEPOOL_CAPACITY_RESERVATION} and ${NODEPOOL_TENANCY}
function config_nodepool() {
    local RESERVATION_ID=""
    local EXTRA_FLARGS=""
    if [[ -n "${NODEPOOL_TENANCY}" || -n "${NODEPOOL_CAPACITY_RESERVATION}" ]]; then
        curl -L "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" -o /tmp/jq && chmod +x /tmp/jq
        curl -L "https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" -o /tmp/yq && chmod +x /tmp/yq
        EXTRA_FLARGS+=$( echo " --render > /tmp/np.yaml " )
    fi

    if [[ -f "${SHARED_DIR}/reservation_id" && -n "${NODEPOOL_CAPACITY_RESERVATION}" ]]; then
        RESERVATION_ID=$(cat ${SHARED_DIR}/reservation_id | /tmp/jq -r .${NODEPOOL_CAPACITY_RESERVATION})
        EXTRA_FLARGS+=" && /tmp/yq e -i '.spec.platform.aws.placement.capacityReservation = {\"id\": \"${RESERVATION_ID}\", \"marketType\": \"${NODEPOOL_CAPACITY_RESERVATION}\"}' /tmp/np.yaml"
    fi
    if [[ -n "${NODEPOOL_TENANCY}" ]]; then
        EXTRA_FLARGS+=" && /tmp/yq e -i '.spec.platform.aws.placement.tenancy = \"${NODEPOOL_TENANCY}\"' /tmp/np.yaml"
    fi
    if [[ -n "${NODEPOOL_TENANCY}" || -n "${NODEPOOL_CAPACITY_RESERVATION}" ]]; then
      EXTRA_FLARGS+=" && oc apply -f /tmp/np.yaml"
    fi
    echo "$EXTRA_FLARGS"    
}

eval "/usr/bin/hypershift create nodepool aws \
  --cluster-name  ${CLUSTER_NAME} \
  --name additional-${CLUSTER_NAME} \
  --node-count ${ADDITIONAL_HYPERSHIFT_NODE_COUNT} \
  --instance-type ${ADDITIONAL_HYPERSHIFT_INSTANCE_TYPE} \
  --arch ${ADDITIONAL_HYPERSHIFT_NODE_ARCH} \
  --release-image ${NODEPOOL_RELEASE_IMAGE_LATEST} $(config_nodepool)"

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

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
