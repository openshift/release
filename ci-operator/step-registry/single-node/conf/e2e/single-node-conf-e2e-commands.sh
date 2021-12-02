#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Reserve more system memory per node than a typical multi-node cluster
# to facilitate E2E tests on a single node.
cat > "${SHARED_DIR}/manifest_single-node-kubeletconfig.yml" << EOF
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

# Use first eight cores on a single node for workload partitioning (see https://github.com/openshift/enhancements/blob/master/enhancements/workload-partitioning/management-workload-partitioning.md#goals)
# ... but avoid applying workload partitioning if OCP version < 4.10 (or if OCP_VERSION is not set)
REQUIRED_OCP_VERSION="4.10"
if [ "$(printf '%s\n' "${REQUIRED_OCP_VERSION}" "${OCP_VERSION}" | sort --version-sort | head -n1)" = "${REQUIRED_OCP_VERSION}" ]; then 
  cat >"${SHARED_DIR}/manifest_single-node-workload-partitioning.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 02-master-workload-partitioning
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,W2NyaW8ucnVudGltZS53b3JrbG9hZHMubWFuYWdlbWVudF0KYWN0aXZhdGlvbl9hbm5vdGF0aW9uID0gInRhcmdldC53b3JrbG9hZC5vcGVuc2hpZnQuaW8vbWFuYWdlbWVudCIKYW5ub3RhdGlvbl9wcmVmaXggPSAicmVzb3VyY2VzLndvcmtsb2FkLm9wZW5zaGlmdC5pbyIKcmVzb3VyY2VzID0geyAiY3B1c2hhcmVzIiA9IDAsICJjcHVzZXQiID0gIjAtNyIgfQ==
        mode: 420
        overwrite: true
        path: /etc/crio/crio.conf.d/01-workload-partitioning
        user:
          name: root
      - contents:
          source: data:text/plain;charset=utf-8;base64,ewogICJtYW5hZ2VtZW50IjogewogICAgImNwdXNldCI6ICIwLTciCiAgfQp9
        mode: 420
        overwrite: true
        path: /etc/kubernetes/openshift-workload-pinning
        user:
          name: root
EOF
fi
