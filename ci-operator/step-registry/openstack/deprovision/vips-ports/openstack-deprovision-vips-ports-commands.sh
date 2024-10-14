#!/usr/bin/env bash

# This script removes two dualstack neutron ports.

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != *"dualstack"* && "$CONFIG_TYPE" != *"singlestackv6"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not being dualstack."
    exit 0
fi

CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml

for p in api ingress; do
  echo "Deleting port: ${CLUSTER_NAME}-${CONFIG_TYPE}-${p}"
  openstack port delete ${CLUSTER_NAME}-${CONFIG_TYPE}-${p} || >&2 echo "Failed to delete port ${CLUSTER_NAME}-${CONFIG_TYPE}-${p}"
done                                               
