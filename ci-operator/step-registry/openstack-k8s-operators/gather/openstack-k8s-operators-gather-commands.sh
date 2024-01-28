#!/usr/bin/env bash

set -x
set +eu

MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"5m"}

mkdir -p ${ARTIFACT_DIR}/must-gather/

# Run the must-gather command
oc --insecure-skip-tls-verify adm must-gather --image-stream=openshift/must-gather \
    --image=quay.io/openstack-k8s-operators/openstack-must-gather:latest \
    --timeout=$MUST_GATHER_TIMEOUT \
    --dest-dir ${ARTIFACT_DIR}/must-gather -- ADDITIONAL_NAMESPACES=kuttl,sushy-emulator gather &> ${ARTIFACT_DIR}/must-gather/openstack-must-gather.log
