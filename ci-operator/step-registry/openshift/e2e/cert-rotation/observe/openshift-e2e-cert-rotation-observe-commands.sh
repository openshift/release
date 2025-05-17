#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ sleeping for ${CLUSTER_OBSERVE_DURATION} ************"
sleep ${CLUSTER_OBSERVE_DURATION}

# Wait for operators to stop progressing
oc adm wait-for-stable-cluster --minimum-stable-period 1m --timeout 30m
