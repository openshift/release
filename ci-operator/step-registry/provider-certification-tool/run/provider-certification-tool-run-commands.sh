#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

if [ -n "${OPCT_DEV_EXTRA_CMD:-}" ]; then
    echo "Running OPCT with regular mode with custom image"
    ${OPCT_EXEC} run --watch ${OPCT_DEV_EXTRA_CMD:-}
elif [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
    echo "Running OPCT with upgrade mode"
    ${OPCT_EXEC} run --watch --mode=upgrade --upgrade-to-image="${TARGET_RELEASE_IMAGE}"
else
    echo "Running OPCT with regular mode"
    ${OPCT_EXEC} run --watch
fi