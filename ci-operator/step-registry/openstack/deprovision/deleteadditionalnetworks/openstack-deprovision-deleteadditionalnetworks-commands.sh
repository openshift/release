#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

if [[ -f "${SHARED_DIR}/ADDITIONAL_SUBNET_IDS" ]]; then
    for SUBNET_ID in $(cat ${SHARED_DIR}/ADDITIONAL_SUBNET_IDS); do
        openstack subnet delete $SUBNET_ID  || true
    done
fi

if [[ -f "${SHARED_DIR}/ADDITIONAL_NETWORK_IDS" ]]; then
    for NETWORK_ID in $(cat ${SHARED_DIR}/ADDITIONAL_NETWORK_IDS); do
        openstack network delete $NETWORK_ID  || true
    done
fi