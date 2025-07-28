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
        EXTRA_FLARGS+=$( echo " --render > /tmp/np.yaml " )
    fi

    if [[ -f "${SHARED_DIR}/reservation_id" && -n "${NODEPOOL_CAPACITY_RESERVATION}" ]]; then
        RESERVATION_ID=$(cat ${SHARED_DIR}/reservation_id)
        EXTRA_FLARGS+=' && sed -i "/^    aws:/a \      placement:\\n        capacityReservation:\\n          id: '${RESERVATION_ID}'\\n          marketType: '${NODEPOOL_CAPACITY_RESERVATION}'" /tmp/np.yaml'
    fi
    if [[ -n "${NODEPOOL_TENANCY}" ]]; then
        if [[ -n "${NODEPOOL_CAPACITY_RESERVATION}" ]]; then
            EXTRA_FLARGS+=' && sed -i "/^      placement:/a \        tenancy: '$NODEPOOL_TENANCY'" /tmp/np.yaml'
        else
            EXTRA_FLARGS+=' && sed -i "/^    aws:/a \      placement:\\n        tenancy: '${NODEPOOL_TENANCY}'" /tmp/np.yaml'
        fi
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
