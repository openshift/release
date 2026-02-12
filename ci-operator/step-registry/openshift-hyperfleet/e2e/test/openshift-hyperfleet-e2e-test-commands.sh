#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

HYPERFLEET_API_URL=$(cat "${SHARED_DIR}/hyperfleet_api_url")
export HYPERFLEET_API_URL
export HYPERFLEET_E2E_CREDENTIALS_PATH="/var/run/hyperfleet-e2e/"
# Run e2e tests via --label-filter
hyperfleet-e2e test --label-filter=${LABEL_FILTER} --junit-report ${ARTIFACT_DIR}/junit.xml
