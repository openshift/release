#!/usr/bin/env bash

set -x
set +eu

MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"5m"}

# OCP must-gather
mkdir -p ${ARTIFACT_DIR}/must-gather/
oc --insecure-skip-tls-verify adm must-gather --timeout=$MUST_GATHER_TIMEOUT \
--dest-dir ${ARTIFACT_DIR}/must-gather > ${ARTIFACT_DIR}/must-gather/must-gather.log

# OSP must-gather
oc --insecure-skip-tls-verify adm must-gather --image=quay.io/openstack-k8s-operators/openstack-must-gather:latest --timeout=$MUST_GATHER_TIMEOUT \
--dest-dir ${ARTIFACT_DIR}/must-gather > ${ARTIFACT_DIR}/must-gather/openstack-must-gather.log
