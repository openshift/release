#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# TODO : Update it once the hyperfleet chart workflow is ready
echo "This is an empty job for openshift-hyperfleet-chart-deployment now. Will update it once the hyperfleet-chart workflow is ready"
helm version
