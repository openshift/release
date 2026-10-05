#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

readonly DEBUG_WAIT_SECONDS=3600

if [[ "${WINDOWS_AWS_UPI_POST_DEBUG_WAIT}" != "true" ]]; then
    echo "AWS UPI Windows post-phase debug wait is disabled; cleanup will continue immediately"
    exit 0
fi

echo "AWS UPI Windows post-phase debug wait is enabled; cleanup will continue after ${DEBUG_WAIT_SECONDS} seconds"
sleep "${DEBUG_WAIT_SECONDS}"
echo "AWS UPI Windows post-phase debug wait complete; cleanup will continue"
