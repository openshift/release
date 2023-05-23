#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "removing networking config if already exists"
/tmp/yq e --inplace 'del(.networking)' ${SHARED_DIR}/install-config.yaml

echo "applying dual-stack networking config"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 192.168.0.0/16
  - cidr: fd65:a1a8:60ad::/112
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  - cidr: fd65:10:128::/56
    hostPrefix: 64
  serviceNetwork:
  - 172.30.0.0/16
  - fd65:172:16::/112
EOF
