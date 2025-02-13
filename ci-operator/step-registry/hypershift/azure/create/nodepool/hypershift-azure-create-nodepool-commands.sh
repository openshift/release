#!/usr/bin/env bash

set -euxo pipefail

if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

CLUSTER_NAME="$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c -20)"
NODEPOOL_NAME="${CLUSTER_NAME}-extra"
SUBNET_ID=$(oc get hc -A -o jsonpath='{.items[0].spec.platform.azure.subnetID}')
echo "$(date) Creating additional NodePool for hosted cluster cluster ${CLUSTER_NAME}"

COMMAND=(
    /usr/bin/hypershift create nodepool azure
    --cluster-name "$CLUSTER_NAME"
    --name "$NODEPOOL_NAME"
    --nodepool-subnet-id "$SUBNET_ID"
)

if [[ -n $ADDITIONAL_HYPERSHIFT_INSTANCE_TYPE ]]; then
    COMMAND+=(--instance-type "$ADDITIONAL_HYPERSHIFT_INSTANCE_TYPE")
fi

if [[ -n $ADDITIONAL_HYPERSHIFT_NODE_COUNT ]]; then
    COMMAND+=(--node-count "$ADDITIONAL_HYPERSHIFT_NODE_COUNT")
fi

if [[ -n $ADDITIONAL_HYPERSHIFT_NODE_ARCH ]]; then
    COMMAND+=(--arch "$ADDITIONAL_HYPERSHIFT_NODE_ARCH")
fi

if [[ -n $HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER ]]; then
    COMMAND+=(--marketplace-offer "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER")
    COMMAND+=(--marketplace-publisher "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER")
    COMMAND+=(--marketplace-sku "$(cat "${SHARED_DIR}"/azure-marketplace-image-sku-extra)")
    COMMAND+=(--marketplace-version "$(cat "${SHARED_DIR}"/azure-marketplace-image-version-extra)")
fi

eval "${COMMAND[@]}"

echo "Waiting for the additional NodePool to be ready"
oc wait --timeout=30m nodepool -n clusters "$NODEPOOL_NAME" --for=condition=Ready=True
oc wait --timeout=30m nodepool -n clusters "$NODEPOOL_NAME" --for=condition=UpdatingConfig=False
oc wait --timeout=30m nodepool -n clusters "$NODEPOOL_NAME" --for=condition=UpdatingVersion=False

echo "Waiting for hosted cluster operators to be ready"
export KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig
oc wait clusteroperators --all --for=condition=Available=True --timeout=30m
oc wait clusteroperators --all --for=condition=Progressing=False --timeout=30m
oc wait clusteroperators --all --for=condition=Degraded=False --timeout=30m

echo "$NODEPOOL_NAME" > "$SHARED_DIR"/hypershift_extra_nodepool_name
