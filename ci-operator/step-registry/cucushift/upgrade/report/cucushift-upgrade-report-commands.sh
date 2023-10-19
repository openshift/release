#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

touch "${ARTIFACTS_DIR}/skip_overall_if_fail"

echo "Gathering overall upgrade sanity test results"
if [[ -f "${SHARED_DIR}/upgrade_e2e_failures" ]]; then
    cat "${SHARED_DIR}/upgrade_e2e_failures" 
    echo "Please investigate these failures from build artifacts"
    exit 1
fi