#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ sleeping for ${CLUSTER_OBSERVE_DURATION} ************"
sleep ${CLUSTER_OBSERVE_DURATION}
