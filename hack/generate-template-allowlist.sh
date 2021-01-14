#!/bin/bash

# This script generates the template allowlist

set -o errexit
set -o nounset
set -o pipefail

CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}

if [[ -n ${BLOCKER:-} ]]; then
    ARGS="--block-new-jobs=$BLOCKER"
fi

${CONTAINER_ENGINE} pull registry.ci.openshift.org/ci/template-deprecator:latest
${CONTAINER_ENGINE} run --rm -v "$PWD:/release:z" registry.ci.openshift.org/ci/template-deprecator:latest \
    ${ARGS:-} \
    --prow-jobs-dir /release/ci-operator/jobs \
    --prow-config-path /release/core-services/prow/02_config/_config.yaml \
    --prow-plugin-config-path /release/core-services/prow/02_config/_plugins.yaml \
    --allowlist-path /release/core-services/template-deprecation/_allowlist.yaml
