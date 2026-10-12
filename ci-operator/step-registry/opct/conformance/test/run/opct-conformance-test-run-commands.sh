#!/bin/bash

#
# Provision the OPCT conformance workflow, watiching the results.
#

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
extract_opct

trap 'dump_opct_namespace' EXIT TERM INT

if [ -n "${OPCT_DEV_EXTRA_CMD:-}" ]; then
    echo "Running OPCT with regular mode with custom image"
    ${OPCT_CLI} run --watch ${OPCT_DEV_EXTRA_CMD:-}
elif [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
    echo "Running OPCT with upgrade mode"
    ${OPCT_CLI} run \
        --watch \
        --mode=upgrade \
        --upgrade-to-image="${TARGET_RELEASE_IMAGE}" \
        --validation-timeout=900 \
        --validation-retry-interval=30
else
    echo "Running OPCT with regular mode"
    ${OPCT_CLI} run \
        --watch \
        --validation-timeout=900 \
        --validation-retry-interval=30
fi
