#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  serviceNetwork:
  - "172.30.0.0/16"
  clusterNetwork:
  - cidr: "10.128.0.0/14"
    hostPrefix: 23
  networkType: OpenShiftSDN
  openshiftSDNConfig:
    mode: Subnet
    vxlanPort: 4789
    enableUnidling: true
    useExternalOpenvswitch: false
EOF
