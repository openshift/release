#!/usr/bin/env bash

#TODO (adduarte) - rework this to use the same function as we currently do for openstack-conf-clouds
set -o nounset
set -o errexit
set -o pipefail

cat <<< "$OS_SUBNET_RANGE"   > "${SHARED_DIR}/OS_SUBNET_RANGE"
cat <<< "$OPENSTACK_COMPUTE_FLAVOR"   > "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR"
cat <<< "$OPENSTACK_MASTER_FLAVOR"   > "${SHARED_DIR}/OPENSTACK_MASTER_FLAVOR"
cat <<< "$NUMBER_OF_MASTERS"   > "${SHARED_DIR}/NUMBER_OF_MASTERS"
cat <<< "$NUMBER_OF_WORKERS"   > "${SHARED_DIR}/NUMBER_OF_WORKERS"