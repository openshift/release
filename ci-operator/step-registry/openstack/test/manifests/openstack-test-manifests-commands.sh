#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
OPENSTACK_COMPUTE_FLAVOR="${OPENSTACK_COMPUTE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")}"

/var/lib/openshift-install/manifest-tests/test-manifests.sh \
  -c "$OS_CLOUD" \
  -f "$OPENSTACK_COMPUTE_FLAVOR" \
  -e "$OPENSTACK_EXTERNAL_NETWORK" \
  -i '/bin/openshift-install' \
  -t '/var/lib/openshift-install/manifest-tests'
