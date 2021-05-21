#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Reserve more system memory per node than a typical multi-node cluster
# to facilitate E2E tests on a single node.
cat > "${SHARED_DIR}/manifest_single-node-reserve-sys-mem-kubeletconfig.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: single-node-reserve-sys-mem
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig: 
    systemReserved:
      memory: 3Gi
EOF
