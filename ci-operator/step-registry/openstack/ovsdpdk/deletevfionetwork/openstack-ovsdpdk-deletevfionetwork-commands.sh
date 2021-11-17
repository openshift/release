#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

if [[ -f "${SHARED_DIR}/VFIO_NETWORK_ID" ]]; then
    while IFS= read -r NETID
    do
      openstack network delete "${NETID}"  || true
    done < "${SHARED_DIR}/VFIO_NETWORK_ID"
fi

