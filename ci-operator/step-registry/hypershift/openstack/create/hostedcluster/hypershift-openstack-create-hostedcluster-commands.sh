#!/bin/bash

set -euo pipefail

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

OPENSTACK_COMPUTE_FLAVOR=$(cat "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")
OPENSTACK_EXTERNAL_NETWORK_ID=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK_ID")

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

# We copy the file here so we can later modify it if needed (e.g. for NFV).
cp /etc/ci-pull-credentials/.dockerconfigjson /tmp/global-pull-secret.json

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
# In order to save CI resources, we use the "InPlace" upgrade type so
# when a node needs to be replacement, we will just restart it with its
# new configuration and not create another that will replace it.
COMMAND=(
  /usr/bin/hcp create cluster openstack
  --name "${CLUSTER_NAME}"
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}"
  --openstack-external-network-id "${OPENSTACK_EXTERNAL_NETWORK_ID}"
  --openstack-node-flavor "${OPENSTACK_COMPUTE_FLAVOR}"
  --node-upgrade-type InPlace
  --base-domain "${HYPERSHIFT_BASE_DOMAIN}"
  --control-plane-availability-policy "${HYPERSHIFT_CP_AVAILABILITY_POLICY}"
  --infra-availability-policy "${HYPERSHIFT_INFRA_AVAILABILITY_POLICY}"
  --pull-secret=/tmp/global-pull-secret.json
  --release-image "${RELEASE_IMAGE}"
  --annotations=hypershift.openshift.io/skip-release-image-validation=true
)

if [ "${NFV_NODEPOOLS}" == "true" ]; then
  if test -f "${SHARED_DIR}/OPENSTACK_DPDK_NETWORK_ID"; then
    OPENSTACK_DPDK_NETWORK_ID="$(<"${SHARED_DIR}/OPENSTACK_DPDK_NETWORK_ID")"
    COMMAND+=("--openstack-node-additional-port=network-id:$OPENSTACK_DPDK_NETWORK_ID,disable-port-security:true")
  fi
  if test -f "${SHARED_DIR}/OPENSTACK_SRIOV_NETWORK_ID"; then
    OPENSTACK_SRIOV_NETWORK_ID="$(<"${SHARED_DIR}/OPENSTACK_SRIOV_NETWORK_ID")"
    COMMAND+=("--openstack-node-additional-port=network-id:$OPENSTACK_SRIOV_NETWORK_ID,vnic-type:direct,disable-port-security:true")
  fi
  # Use private credentials to pull CNF images for SR-IOV network operator
  # Credentials are in shiftstack vault: shiftstack-secrets/quay-openshift-credentials
  QUAY_USERNAME=$(cat /var/run/quay-openshift-credentials/quay_username)
  QUAY_PASSWORD=$(cat /var/run/quay-openshift-credentials/quay_password)
  QUAY_AUTH=$(echo -n "${QUAY_USERNAME}:${QUAY_PASSWORD}" | base64 -w 0)
  curl -s -L https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /tmp/jq && chmod +x /tmp/jq
  /tmp/jq --arg QUAY_AUTH "$QUAY_AUTH" '.auths += {"quay.io/openshift": {"auth":$QUAY_AUTH}}' /tmp/global-pull-secret.json > /tmp/global-pull-secret.json.tmp
  mv /tmp/global-pull-secret.json.tmp /tmp/global-pull-secret.json
fi

if [[ $ENABLE_ICSP == "true" ]]; then
  COMMAND+=(--image-content-sources "${SHARED_DIR}/mgmt_icsp.yaml")
fi

if [ -f "${SHARED_DIR}/HCP_INGRESS_IP" ]; then
  HCP_INGRESS_IP=$(<"${SHARED_DIR}/HCP_INGRESS_IP")
  COMMAND+=(--openstack-ingress-floating-ip "${HCP_INGRESS_IP}")
fi

if [[ -n $RHCOS_IMAGE_NAME ]]; then
  COMMAND+=(--openstack-node-image-name "${RHCOS_IMAGE_NAME}")
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
