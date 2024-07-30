#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

if [ ! -f "${SHARED_DIR}/INGRESS_PORT_ID" ]; then
  echo "No ingress port ID found, nothing to clean"
  exit 0
fi

INGRESS_PORT_ID="${INGRESS_PORT_ID:-$(<"${SHARED_DIR}/INGRESS_PORT_ID")}"
echo "Deleting ingress port with ID: $INGRESS_PORT_ID"
openstack port delete "$INGRESS_PORT_ID"

echo "Done"
