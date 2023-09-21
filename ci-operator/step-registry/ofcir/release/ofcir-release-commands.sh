#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ ofcir packet teardown command ************"

set -x
CIRFILE=$SHARED_DIR/cir
if [ -e $CIRFILE ] ; then
    OFCIRURL="https://ofcir-service.ofcir-system.svc.cluster.local/v1/ofcir"
    OFCIRTOKEN="$(cat ${CLUSTER_PROFILE_DIR}/ofcir-auth-token)"
    rv="$(cat ${SHARED_DIR}/install-status.txt | head -n 1 | awk '{print $1}' 2> /dev/null || echo 99)"
    echo Skipping
    exit 0
fi
