#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

node_role=${APPLY_NODE_ROLE:=worker}
log_path=${LOG_PATH:="/var/crash"}

echo "Creating kdump configuration"
kdump_conf=$(cat <<EOF | base64 -w 0
path $log_path
core_collector makedumpfile -l --message-level 7 -d 31
EOF
)

echo "Creating kdump sysconfig"
kdump_sysconfig=$(cat <<EOF
KDUMP_COMMANDLINE_REMOVE="${KDUMP_COMMANDLINE_REMOVE}"
KDUMP_COMMANDLINE_APPEND="${KDUMP_COMMANDLINE_APPEND}"
KEXEC_ARGS="${KDUMP_KEXEC_ARGS}"
KDUMP_IMG="${KDUMP_IMG}"
EOF
)
echo "$kdump_sysconfig"
base64_kdump_sysconfig=$(echo "$kdump_sysconfig" | base64 -w 0)

echo "Configuring kernel dumps on $node_role nodes"
cat >> "${SHARED_DIR}/manifest_99_kdump_machineconfig.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $node_role
  name: 99-$node_role-kdump
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,${kdump_conf}
          mode: 420
          overwrite: true
          path: /etc/kdump.conf
        - contents:
            source: data:text/plain;charset=utf-8;base64,${base64_kdump_sysconfig}
          mode: 420
          overwrite: true
          path: /etc/sysconfig/kdump
    systemd:
      units:
        - enabled: true
          name: kdump.service
EOF

echo "Crash kernel to ${CRASH_KERNEL_MEMORY}"
cat >> "${SHARED_DIR}/manifest_99_kdump_machineconfig.yml" << EOF
  kernelArguments:
    - crashkernel="${CRASH_KERNEL_MEMORY}"
EOF

cat "${SHARED_DIR}/manifest_99_kdump_machineconfig.yml"