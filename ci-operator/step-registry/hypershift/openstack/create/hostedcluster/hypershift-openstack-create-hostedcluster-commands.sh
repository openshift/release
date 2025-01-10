#!/bin/bash

set -euo pipefail

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

OPENSTACK_COMPUTE_FLAVOR=$(cat "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")
OPENSTACK_EXTERNAL_NETWORK_ID=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK_ID")

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME="$(echo -n "$PROW_JOB_ID"|sha256sum|cut -c-20)"
echo "$CLUSTER_NAME" > "${SHARED_DIR}/CLUSTER_NAME"
echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
COMMAND=(
  /usr/bin/hcp create cluster openstack
  --name "${CLUSTER_NAME}"
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}"
  --openstack-external-network-id "${OPENSTACK_EXTERNAL_NETWORK_ID}"
  --openstack-node-flavor "${OPENSTACK_COMPUTE_FLAVOR}"
  --openstack-node-image-name "${RHCOS_IMAGE_NAME}"
  --base-domain "${HYPERSHIFT_BASE_DOMAIN}"
  --control-plane-availability-policy "${HYPERSHIFT_CP_AVAILABILITY_POLICY}"
  --infra-availability-policy "${HYPERSHIFT_INFRA_AVAILABILITY_POLICY}"
  --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson
  --release-image "${RELEASE_IMAGE}"
  --annotations=hypershift.openshift.io/skip-release-image-validation=true
)

if [[ $ENABLE_ICSP == "true" ]]; then
  COMMAND+=(--image-content-sources "${SHARED_DIR}/mgmt_icsp.yaml")
fi

if [ -f "${SHARED_DIR}/HCP_INGRESS_IP" ]; then
  HCP_INGRESS_IP=$(<"${SHARED_DIR}/HCP_INGRESS_IP")
  COMMAND+=(--openstack-ingress-floating-ip "${HCP_INGRESS_IP}")
fi

if [[ -n $EXTRA_ARGS ]]; then
  COMMAND+=("${EXTRA_ARGS}")
fi

if [[ -n ${ETCD_STORAGE_CLASS} ]]; then
  COMMAND+=(--etcd-storage-class "${ETCD_STORAGE_CLASS}")
fi

if [[ $HYPERSHIFT_CREATE_CLUSTER_RENDER == "true" ]]; then
  "${COMMAND[@]}" --render > "${SHARED_DIR}/hypershift_create_cluster_render.yaml"
  exit 0
fi

"${COMMAND[@]}"

export CLUSTER_NAME
oc wait --timeout=30m --for=condition=Available --namespace=clusters "hostedcluster/${CLUSTER_NAME}"
echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --namespace=clusters --name="${CLUSTER_NAME}" > "${SHARED_DIR}/nested_kubeconfig"
