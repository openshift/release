#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# set shutdown grace period to enable testing for graceful shutdown.
cat > "${SHARED_DIR}/manifest_single-node-graceful-shutdown-kubeletconfig.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: single-node-reserve-sys-mem
spec:
  containers:
    machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    shutdownGracePeriod: 600s
    shutdownGracePeriodCriticalPods: 300s
EOF
