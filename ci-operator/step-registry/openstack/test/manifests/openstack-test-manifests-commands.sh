#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
OS_CLOUD='openstack'
OPENSTACK_INSTANCE_FLAVOR=$(<"${SHARED_DIR}/OPENSTACK_INSTANCE_FLAVOR")
OPENSTACK_EXTERNAL_NETWORK=$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")

/var/lib/openshift-install/manifest-tests/test-manifests.sh \
  -c "$OS_CLOUD" \
  -f "$OPENSTACK_INSTANCE_FLAVOR" \
  -e "$OPENSTACK_EXTERNAL_NETWORK" \
  -i '/bin/openshift-install' \
  -t '/var/lib/openshift-install/manifest-tests'
