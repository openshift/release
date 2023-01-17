#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
# Recycling BASTION_FLAVOR as it's a small flavor we can re-use.
TESTING_FLAVOR="${TESTING_FLAVOR:-$(<"${SHARED_DIR}/BASTION_FLAVOR")}"

set +e
echo "DEBUG: Running liveliness check script..."
./server.sh -d -t -l -f ${TESTING_FLAVOR} -i ${TESTING_IMAGE} -e ${OPENSTACK_EXTERNAL_NETWORK} shiftstack-ci-${CLUSTER_NAME}
RC=$?
set -e

if [ $RC -ne 0 ]; then
  echo "ERROR: Some errors were found during liveliness check..."
  exit 1
fi

echo "DEBUG: Cloud is alive!"
