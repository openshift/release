#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# only exit 0 if junit result has no failures
if [[ -f "${SHARED_DIR}/cucushift-e2e-failures" ]]; then
    cat "${SHARED_DIR}/cucushift-e2e-failures"
    echo "Please investigate these failures from build artifacts"
    exit 1
fi
