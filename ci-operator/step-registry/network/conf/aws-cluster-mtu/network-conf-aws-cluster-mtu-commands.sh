#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${ARTIFACT_DIR}/install-config.patch.yaml"

export PATH=${PATH}:/tmp

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

echo_date "Creating Network Configuration on install-config.yaml using type [${NETWORK_TYPE}] and MTU [${CLUSTER_NETWORK_MTU}]"

cat >> "${PATCH}" << EOF
networking:
  clusterNetworkMTU: ${CLUSTER_NETWORK_MTU}
  networkType: "${NETWORK_TYPE}"
EOF

yq-v4 ea -i '. as $item ireduce ({}; . *+ $item)' "${CONFIG}" "${PATCH}"