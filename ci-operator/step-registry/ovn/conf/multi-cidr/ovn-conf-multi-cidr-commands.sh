#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/22
    hostPrefix: 23
  - cidr: 10.128.4.0/22
    hostPrefix: 23
  - cidr: 10.128.8.0/22
    hostPrefix: 23
EOF

echo "install-config.yaml with multi-cidr clusterNetwork:"
cat "${SHARED_DIR}/install-config.yaml"
