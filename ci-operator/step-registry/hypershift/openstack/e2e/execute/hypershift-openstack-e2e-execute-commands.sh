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
OPENSTACK_EXTERNAL_NETWORK_ID=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK_ID")

if [ ! -f "${SHARED_DIR}/clouds.yaml" ]; then
    >&2 echo clouds.yaml has not been generated
    exit 1
fi

# run the test
hack/ci-test-e2e.sh \
        --test.v \
        --test.timeout=0 \
        --e2e.latest-release-image=${OCP_IMAGE_LATEST} \
        --e2e.previous-release-image=${OCP_IMAGE_PREVIOUS} \
        --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
        --e2e.node-pool-replicas=2 \
	--e2e.aws-credentials-file=${CLUSTER_PROFILE_DIR}/.awscred \
	--e2e.base-domain=origin-ci-int-aws.dev.rhcloud.com \
        --test.run='^TestCreateCluster$' \
	--test.parallel=1 \
        --e2e.platform="OpenStack" \
	--e2e.ssh-key-file="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --e2e.openstack-credentials-file="${SHARED_DIR}/clouds.yaml" \
        --e2e.openstack-external-network-id="${OPENSTACK_EXTERNAL_NETWORK_ID}" \
        --e2e.openstack-node-flavor="${OPENSTACK_COMPUTE_FLAVOR}" \
	--e2e.openstack-node-image-name="rhcos-4.17-hcp-nodepool"
