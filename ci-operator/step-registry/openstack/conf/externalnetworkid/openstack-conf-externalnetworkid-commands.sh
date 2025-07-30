#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

declare OPENSTACK_EXTERNAL_NETWORK_ID
if [[ -n "$OPENSTACK_EXTERNAL_NETWORK" ]]; then
	OPENSTACK_EXTERNAL_NETWORK_ID=$(openstack network show "${OPENSTACK_EXTERNAL_NETWORK}" -f value -c id)
	cat <<< "$OPENSTACK_EXTERNAL_NETWORK_ID" > "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK_ID"
	echo "OPENSTACK_EXTERNAL_NETWORK_ID: $OPENSTACK_EXTERNAL_NETWORK_ID"
fi

if [[ -n ${OPENSTACK_DPDK_NETWORK} ]]; then
        if ! openstack network show "${OPENSTACK_DPDK_NETWORK}" >/dev/null 2>&1; then
                echo "DPDK network ${OPENSTACK_DPDK_NETWORK} does not exist"
                exit 1
        fi
        OPENSTACK_DPDK_NETWORK_ID=$(openstack network show -f value -c id "${OPENSTACK_DPDK_NETWORK}")
        cat <<< "$OPENSTACK_DPDK_NETWORK_ID" > "${SHARED_DIR}/OPENSTACK_DPDK_NETWORK_ID"
        echo "OPENSTACK_DPDK_NETWORK_ID: $OPENSTACK_DPDK_NETWORK_ID"
fi

if [[ -n ${OPENSTACK_SRIOV_NETWORK} ]]; then
        if ! openstack network show "${OPENSTACK_SRIOV_NETWORK}" >/dev/null 2>&1; then
                echo "SR-IOV network ${OPENSTACK_SRIOV_NETWORK} does not exist"
                exit 1
        fi
        OPENSTACK_SRIOV_NETWORK_ID=$(openstack network show -f value -c id "${OPENSTACK_SRIOV_NETWORK}")
        cat <<< "$OPENSTACK_SRIOV_NETWORK_ID" > "${SHARED_DIR}/OPENSTACK_SRIOV_NETWORK_ID"
        echo "OPENSTACK_SRIOV_NETWORK_ID: $OPENSTACK_SRIOV_NETWORK_ID"
fi