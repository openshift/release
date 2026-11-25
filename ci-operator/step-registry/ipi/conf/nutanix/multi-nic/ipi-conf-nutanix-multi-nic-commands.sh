#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
  NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
  NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi
declare multi_nics
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch-multi-nics.yaml"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    subnetUUIDs:
    - $multi_nics
EOF

yq-go m -a -i "${CONFIG}" "${PATCH}"
echo "Updated multi-nics in '${CONFIG}'."

echo "The updated multi-nics:"
yq-go r "${CONFIG}" platform.nutanix.subnetUUIDs
