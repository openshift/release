#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

echo "Patching rendered HostedCluster YAML to enable Routes"
sed --in-place "s/type: LoadBalancer/type: Route/" "${SHARED_DIR}"/hypershift_create_cluster_render.yaml

echo "Applying patched artifacts"
oc apply -f "${SHARED_DIR}"/hypershift_create_cluster_render.yaml

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=$HYPERSHIFT_NAMESPACE hostedcluster/${CLUSTER_NAME}

echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --namespace=$HYPERSHIFT_NAMESPACE --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig

echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
