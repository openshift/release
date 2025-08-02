#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/99-openshift-nodes-swap-memory-enabled.yaml" << EOF
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-kernel-swapcount-arg
spec:
  kernelArguments:
    - swapaccount=1
EOF

if [[ "${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}" == "swap" ]]; then
    cat >> "${SHARED_DIR}/99-openshift-nodes-swap-memory-enabled.yaml" << EOF
---
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: 99-swap-config-master
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    failSwapOn: false 
    memorySwap:
      swapBehavior: LimitedSwap
EOF
fi

if [[ "${AZURE_COMPUTE_MULTIDISK_TYPE}" == "swap" ]]; then
    cat >> "${SHARED_DIR}/99-openshift-nodes-swap-memory-enabled.yaml" << EOF
---
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: 99-swap-config-worker
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    failSwapOn: false
    memorySwap:
      swapBehavior: LimitedSwap
EOF
fi

echo "swap manifests yaml file:"
cat "${SHARED_DIR}"/99-openshift-nodes-swap-memory-enabled.yaml
