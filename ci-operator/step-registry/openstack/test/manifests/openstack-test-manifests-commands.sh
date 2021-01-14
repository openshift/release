#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${CLUSTER_PROFILE_DIR}/clouds.yaml"

/var/lib/openshift-install/manifest-tests/test-manifests.sh \
  -c "$OS_CLOUD" \
  -f "$OPENSTACK_INSTANCE_FLAVOR" \
  -e "$OPENSTACK_EXTERNAL_NETWORK" \
  -i '/bin/openshift-install' \
  -t '/var/lib/openshift-install/manifest-tests'
