#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

if [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
    echo "Running OPCT with upgrade mode"
    ${OPCT_EXEC} run --watch --mode=upgrade --upgrade-to-image="${TARGET_RELEASE_IMAGE}"
else
    echo "Running OPCT with regular mode"
    ${OPCT_EXEC} run --watch
fi