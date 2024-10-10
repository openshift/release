#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

CONFIG_UPDNS="${SHARED_DIR}/install-config-updns.yaml.patch"
cat > "${CONFIG_UPDNS}" << EOF
platform:
  aws:
    userProvisionedDNS: Enabled
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_UPDNS}"
