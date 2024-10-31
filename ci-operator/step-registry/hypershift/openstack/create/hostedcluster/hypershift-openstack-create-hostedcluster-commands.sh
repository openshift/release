#!/bin/bash

set -euo pipefail

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

if [ -f "${SHARED_DIR}/osp-ca.crt" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --openstack-ca-cert-file ${SHARED_DIR}/osp-ca.crt"
fi

OPENSTACK_COMPUTE_FLAVOR=$(cat "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")
OPENSTACK_EXTERNAL_NETWORK_ID=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK_ID")

if [ ! -f "${SHARED_DIR}/clouds.yaml" ]; then
    >&2 echo clouds.yaml has not been generated
    exit 1
fi

# If the base domain is not set, default to the origin-ci-int-aws.dev.rhcloud.com domain
# which is the domain used by the management cluster running on AWS and therefore the
# credentials we have access to.
if [ -z "${HYPERSHIFT_BASE_DOMAIN}" ]; then
  HYPERSHIFT_BASE_DOMAIN="origin-ci-int-aws.dev.rhcloud.com"
fi

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
  /usr/bin/hypershift create cluster openstack
  --name "${CLUSTER_NAME}"
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}"
  --openstack-credentials-file "${SHARED_DIR}/clouds.yaml"
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

if [ -f "${SHARED_DIR}/osp-ca.crt" ]; then
  COMMAND+=(--openstack-ca-cert-file "${SHARED_DIR}/osp-ca.crt")
fi

if [[ $ENABLE_ICSP == "true" ]]; then
  COMMAND+=(--image-content-sources "${SHARED_DIR}/mgmt_icsp.yaml")
fi

if [[ -n $EXTRA_ARGS ]]; then
  COMMAND+=("${EXTRA_ARGS}")
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

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
timeout 25m bash -c '
  echo "Waiting for router-default to have an IP"
  until [[ "$(oc -n openshift-ingress get service router-default -o jsonpath="{.status.loadBalancer.ingress[0].ip}")" != "" ]]; do
      sleep 15
      echo "router-default does not exist yet, retrying..."
  done
'
INGRESS_IP=$(oc -n openshift-ingress get service router-default -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [[ -z "${INGRESS_IP}" ]]; then
  echo "Ingress IP was not found"
  exit 1
fi
echo "${INGRESS_IP}" > "${SHARED_DIR}/INGRESS_IP"
echo "Ingress IP was found: ${INGRESS_IP}"
