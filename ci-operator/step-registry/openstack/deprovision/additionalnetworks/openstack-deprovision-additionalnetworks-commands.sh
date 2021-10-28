#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml

if [[ -f "${SHARED_DIR}/ADDITIONALSUBNETIDS" ]]; then
    for SUBNET_ID in $(cat ${SHARED_DIR}/ADDITIONALSUBNETIDS); do
        openstack subnet delete $SUBNET_ID  || true
    done
fi

if [[ -f "${SHARED_DIR}/ADDITIONALSUBNETIDS" ]]; then
    for NETWORK_ID in $(cat ${SHARED_DIR}/ADDITIONALNETWORKIDS); do
        openstack network delete $NETWORK_ID  || true
    done
fi