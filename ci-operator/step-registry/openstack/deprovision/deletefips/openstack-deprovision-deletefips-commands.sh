#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
export OS_CLOUD="$CLUSTER_TYPE"

if [[ -f "${SHARED_DIR}/DELETE_FIPS" ]]; then
    for FIP in $(cat ${SHARED_DIR}/DELETE_FIPS); do
        openstack floating ip delete ${FIP}  || true
    done
fi
