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
OPENSTACK_EXTERNAL_NETWORK=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")

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
        --e2e.base-domain=ci.hypershift.devcluster.openshift.com \
        --e2e.external-dns-domain=service.ci.hypershift.devcluster.openshift.com \
        --test.run='^TestCreateCluster$' \
        --e2e.platform="OpenStack" \
        --e2e.openstack-credentials-file="${SHARED_DIR}/clouds.yaml" \
        --e2e.openstack-external-network-name="${OPENSTACK_EXTERNAL_NETWORK}" \
        --e2e.openstack-node-flavor="${OPENSTACK_COMPUTE_FLAVOR}"
