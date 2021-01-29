#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Here we import the cloud credentials and set cloud-specific configuration.
#
# These conventions are expected to be respected in the steps:
#
# * OS_CLIENT_CONFIG_FILE is in "${SHARED_DIR}/clouds.yaml"
# * OS_CLOUD is 'openstack'

# We have to truncate cluster name to 14 chars, because there is a limitation in the install-config
# Now it looks like "ci-op-rl6z646h-65230".
# We will remove "ci-op-" prefix from there to keep just last 14 characters. and it cannot start with a "-"
UNSAFE_CLUSTER_NAME=${NAMESPACE}-${JOB_NAME_HASH}
SAFE_CLUSTER_NAME=${UNSAFE_CLUSTER_NAME#"ci-op-"}

case "$CLUSTER_TYPE" in
  openstack-vexxhost)
    OS_CLIENT_CONFIG_FILE="$OS_CLIENT_CONFIG_FILE_VEXXHOST"
    ;;
  openstack)
    OS_CLIENT_CONFIG_FILE="$OS_CLIENT_CONFIG_FILE_MOC"
    ;;
  *)
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
    ;;
esac

cp   "$OS_CLIENT_CONFIG_FILE"   "${SHARED_DIR}/clouds.yaml"
echo "$SAFE_CLUSTER_NAME"     > "${SHARED_DIR}/CLUSTER_NAME"
