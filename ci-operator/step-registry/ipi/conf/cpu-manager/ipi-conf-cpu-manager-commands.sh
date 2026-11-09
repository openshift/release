#!/bin/bash

set -euo pipefail

# Kubelet configuration to enable the CPU Manager:
# - https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/scalability_and_performance/using-cpu-manager
cat > "${SHARED_DIR}/manifest_cpumanager_kubeletconfig.yaml" <<EOF
---
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: cpu-manager-enabled
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${CPU_MANAGER_MCP}: ""
  kubeletConfig:
     cpuManagerPolicy: static
     cpuManagerReconcilePeriod: 5s
EOF
