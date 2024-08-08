#!/bin/bash

set -euo pipefail
set -x

function cleanup() {
for child in $( jobs -p ); do
  kill "${child}"
done
wait
}
trap cleanup EXIT

# compile the e2e tests
make e2e

OPENSTACK_COMPUTE_FLAVOR=$(cat "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")
INGRESS_FIP=$(cat "${SHARED_DIR}/INGRESS_IP")
OPENSTACK_EXTERNAL_NETWORK_ID=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK_ID")

if [ ! -f "${SHARED_DIR}/clouds.yaml" ]; then
    >&2 echo clouds.yaml has not been generated
    exit 1
fi

# TODO(emilien) come back to this.
# We have to specify a cluster name for e2e tests because at this point we already
# created the DNS record for the HostedCluster Ingress endpoint.
# Because of that we can't run more than one test in parallel.
if [ -f "${SHARED_DIR}/CLUSTER_NAME" ]; then
  CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
else
  HASH="$(echo -n "$PROW_JOB_ID"|sha256sum)"
  CLUSTER_NAME=${HASH:0:20}
fi
export CLUSTER_NAME

# run the test
hack/ci-test-e2e.sh \
        --test.v \
        --test.timeout=0 \
        --e2e.latest-release-image=${OCP_IMAGE_LATEST} \
        --e2e.previous-release-image=${OCP_IMAGE_PREVIOUS} \
        --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
        --e2e.node-pool-replicas=2 \
        --e2e.base-domain="${BASE_DOMAIN}" \
        --e2e.external-dns-domain="service.${BASE_DOMAIN}" \
	--test.run='^TestCreateCluster.*|^TestNodePool$' \
	--test.parallel=1 \
        --e2e.platform="OpenStack" \
	--e2e.ssh-key-file="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --e2e.openstack-credentials-file="${SHARED_DIR}/clouds.yaml" \
	--e2e.openstack-ingress-floating-ip="${INGRESS_FIP}" \
	--e2e.openstack-ingress-provider="Octavia" \
        --e2e.openstack-external-network-id="${OPENSTACK_EXTERNAL_NETWORK_ID}" \
        --e2e.openstack-node-flavor="${OPENSTACK_COMPUTE_FLAVOR}" \
	--e2e.openstack-node-image-name="rhcos-4.17-hcp-nodepool"
