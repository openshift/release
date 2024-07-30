#!/bin/bash

set -exuo pipefail

OPENSTACK_COMPUTE_FLAVOR=$(cat "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")
OPENSTACK_EXTERNAL_NETWORK=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")
RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}
NODEPOOL_IMAGE_NAME=${NODEPOOL_IMAGE_NAME:-rhcos-hcp-nodepool}

HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INFRA_ID=${HASH:20:5}
echo "Using cluster name $CLUSTER_NAME and infra id $INFRA_ID"

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
fi
BASEDOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")

if [ ! -f "${SHARED_DIR}/clouds.yaml" ]; then
    >&2 echo clouds.yaml has not been generated
    exit 1
fi

echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
oc create ns "clusters-${CLUSTER_NAME}"

echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm

/usr/bin/hypershift create cluster openstack \
  --name "${CLUSTER_NAME}" \
  --infra-id "${INFRA_ID}" \
  --pull-secret /tmp/.dockerconfigjson \
  --base-domain "${BASEDOMAIN}" \
  --release-image ${RELEASE_IMAGE} \
  --ssh-key "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
  --openstack-credentials-file "${SHARED_DIR}/clouds.yaml" \
  --openstack-external-network-name "${OPENSTACK_EXTERNAL_NETWORK}" \
  --openstack-node-flavor "${OPENSTACK_COMPUTE_FLAVOR}" \
  --openstack-node-image-name "${NODEPOOL_IMAGE_NAME}" \
  --annotations "prow.k8s.io/job=${JOB_NAME}" \
  --annotations "prow.k8s.io/build-id=${BUILD_ID}"

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
/usr/bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig
