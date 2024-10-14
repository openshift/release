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
E2E_TESTS_PARALLEL=2
E2E_EXTRA_ARGS=""

if [ ! -f "${SHARED_DIR}/clouds.yaml" ]; then
    >&2 echo clouds.yaml has not been generated
    exit 1
fi

if [ "${NFV_NODEPOOLS}" == "true" ]; then
    # TODO(emilien): be more specific on the regex to only select the NFV related tests.
    E2E_TESTS_REGEX='^TestNodePool$'
    # NFV's flavor uses dedicated CPU so we can't deploy many nodepools at the same time
    E2E_TESTS_PARALLEL=1
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

if [ -f "${SHARED_DIR}/osp-ca.crt" ]; then
    E2E_EXTRA_ARGS="${E2E_EXTRA_ARGS} --e2e.openstack-ca-cert-file ${SHARED_DIR}/osp-ca.crt"
fi

# run the test
hack/ci-test-e2e.sh ${E2E_EXTRA_ARGS} \
        --test.v \
	-test.timeout=2h30m \
        --e2e.latest-release-image=${OCP_IMAGE_LATEST} \
        --e2e.previous-release-image=${OCP_IMAGE_PREVIOUS} \
        --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
        --e2e.node-pool-replicas=2 \
	--e2e.aws-credentials-file=${CLUSTER_PROFILE_DIR}/.awscred \
	--e2e.base-domain=origin-ci-int-aws.dev.rhcloud.com \
        --test.run="${E2E_TESTS_REGEX}" \
	--test.parallel="${E2E_TESTS_PARALLEL}" \
        --e2e.platform="OpenStack" \
	--e2e.ssh-key-file="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --e2e.openstack-credentials-file="${SHARED_DIR}/clouds.yaml" \
        --e2e.openstack-external-network-id="${OPENSTACK_EXTERNAL_NETWORK_ID}" \
        --e2e.openstack-node-flavor="${OPENSTACK_COMPUTE_FLAVOR}" \
	--e2e.openstack-node-image-name="${RHCOS_IMAGE_NAME}"
