#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# TODO : implement the hyperfleet e2e CI workflow here
echo "This is an empty job for openshift-hyperfleet-e2e-cluster now. Will update it once the hyperfleet-e2e test cases are ready"
GCP_PROJECT_ID=$(cat "${HYPERFLEET_E2E_PATH}/gcp_project_id")
if [[ "${GCP_PROJECT_ID}" =~ "hcm" ]]; then
    echo "Get the GCP project successfully"
fi