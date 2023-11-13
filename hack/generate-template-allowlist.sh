#!/bin/bash

# This script generates the template allowlist

set -o errexit
set -o nounset
set -o pipefail

CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}
CONTAINER_ENGINE_OPTS=${CONTAINER_ENGINE_OPTS:-"--platform linux/amd64"}
SKIP_PULL=${SKIP_PULL:-false}

if [ -z ${VOLUME_MOUNT_FLAGS+x} ]; then echo "VOLUME_MOUNT_FLAGS is unset" && VOLUME_MOUNT_FLAGS=':z'; fi

if [[ -n ${BLOCKER:-} ]]; then
    ARGS="--block-new-jobs=$BLOCKER"
fi

set -x

${SKIP_PULL} || ${CONTAINER_ENGINE} pull ${CONTAINER_ENGINE_OPTS} registry.ci.openshift.org/ci/template-deprecator:latest
${CONTAINER_ENGINE} run ${CONTAINER_ENGINE_OPTS} --rm -v "$PWD:/release${VOLUME_MOUNT_FLAGS}" registry.ci.openshift.org/ci/template-deprecator:latest \
    ${ARGS:-} \
    --prow-jobs-dir /release/ci-operator/jobs \
    --prow-config-path /release/core-services/prow/02_config/_config.yaml \
    --plugin-config /release/core-services/prow/02_config/_plugins.yaml \
    --allowlist-path /release/core-services/template-deprecation/_allowlist.yaml
