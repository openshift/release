#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "appending dual-stack machineNetwork config"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 10.0.0.0/16
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

# DualStack is only enabled by default on Openshift 4.8+
# it requires to enable the feature gate in 4.7
if [[ ${REQUIRE_IPV6_DUALSTACK_NO_UPGRADE} == "true" ]]; then
  echo "Adding IPv6DualStackNoUpgrade feature gate"
  cat >> "${SHARED_DIR}/manifest_ipv6-dual-stack-no-upgrade.yaml.yml" << EOF
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: IPv6DualStackNoUpgrade
EOF
fi
