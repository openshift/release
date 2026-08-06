#!/bin/bash
set -euo pipefail

cat <<EOF > ${SHARED_DIR}/manifest_kubeletconfig_graceful_shutdown.yaml
---
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: graceful-shutdown
  namespace: openshift-machine-config-operator
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${ROLE}: ""
  kubeletConfig:
    shutdownGracePeriod: "${GRACE_PERIOD}"
    shutdownGracePeriodCriticalPods: "${GRACE_PERIOD_CRITICAL_PODS}"
EOF
