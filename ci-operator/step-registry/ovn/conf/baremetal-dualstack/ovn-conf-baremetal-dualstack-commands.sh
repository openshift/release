#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [ -f "${SHARED_DIR}/install-config.yaml" ]; then
    curl -L https://github.com/mikefarah/yq/releases/download/v4.27.2/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
    echo "removing networking config if already exists"
    /tmp/yq e --inplace 'del(.networking)' ${SHARED_DIR}/install-config.yaml
fi

echo "applying dual-stack networking config"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 192.168.0.0/16
  - cidr: fd00::/48
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  - cidr: fd00:10:128::/56
    hostPrefix: 64
  serviceNetwork:
  - 172.30.0.0/16
  - fd00:172:16::/112
EOF
