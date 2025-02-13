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

OPENSTACK_COMPUTE_FLAVOR=$(cat "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")
OPENSTACK_EXTERNAL_NETWORK_ID=$(cat "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK_ID")
E2E_EXTRA_ARGS=""

if [ ! -f "${SHARED_DIR}/clouds.yaml" ]; then
    >&2 echo clouds.yaml has not been generated
    exit 1
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

# run the test
hack/ci-test-e2e.sh ${E2E_EXTRA_ARGS} \
        --test.v \
	--test.timeout=2h30m \
        --e2e.latest-release-image=${OCP_IMAGE_LATEST} \
        --e2e.previous-release-image=${OCP_IMAGE_PREVIOUS} \
        --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
        --e2e.node-pool-replicas=2 \
	--e2e.aws-credentials-file=${CLUSTER_PROFILE_DIR}/.awscred \
	--e2e.base-domain=origin-ci-int-aws.dev.rhcloud.com \
        --test.run="${E2E_TESTS_REGEX}" \
	--test.parallel=20 \
        --e2e.platform="OpenStack" \
	--e2e.ssh-key-file="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --e2e.openstack-credentials-file="${SHARED_DIR}/clouds.yaml" \
        --e2e.openstack-external-network-id="${OPENSTACK_EXTERNAL_NETWORK_ID}" \
        --e2e.openstack-node-flavor="${OPENSTACK_COMPUTE_FLAVOR}" \
	--e2e.openstack-node-image-name="${RHCOS_IMAGE_NAME}" \
	--e2e.annotations="hypershift.openshift.io/cleanup-orc-image-resource=false"
