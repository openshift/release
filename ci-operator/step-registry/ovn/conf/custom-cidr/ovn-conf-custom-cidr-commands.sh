#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "update cidr to 20 to the max nodes num is 8"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/20
    hostPrefix: 23
EOF
