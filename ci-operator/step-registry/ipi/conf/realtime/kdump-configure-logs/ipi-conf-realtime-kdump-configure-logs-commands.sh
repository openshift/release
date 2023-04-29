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
kdump_sysconfig=$(cat <<EOF | base64 -w 0
KDUMP_COMMANDLINE_REMOVE="hugepages hugepagesz slub_debug quiet log_buf_len swiotlb"
KDUMP_COMMANDLINE_APPEND="irqpoll nr_cpus=1 reset_devices cgroup_disable=memory mce=off numa=off udev.children-max=2 panic=10 rootflags=nofail acpi_no_memhotplug transparent_hugepage=never nokaslr novmcoredd hest_disable"
KEXEC_ARGS="-s"
KDUMP_IMG="vmlinuz"
EOF
)

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
            source: data:text/plain;charset=utf-8;base64,${kdump_sysconfig}
          mode: 420
          overwrite: true
          path: /etc/sysconfig/kdump
    systemd:
      units:
        - enabled: true
          name: kdump.service
  kernelArguments:
    - crashkernel=256M
EOF