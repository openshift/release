#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

if [[ -n "${DISK_NAME}" ]]; then
cat > "${SHARED_DIR}/manifest_99-master-etcd-local-${DISK_NAME}.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-etcd-local-${DISK_NAME}
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      disks:
      - device: /dev/${DISK_NAME}
        wipeTable: true
        partitions:
        - label: etcd
          number: 1
      filesystems:
      - device: /dev/disk/by-partlabel/etcd
        format: xfs
        path: /var/lib/etcd
        wipeFilesystem: true
    systemd:
      units:
      - name: var-lib-etcd.mount
        enabled: true
        contents: |
          [Unit]
          Description=Mount Local NVMe (${DISK_NAME}) for etcd
          After=ostree-remount.service var.mount
          Before=local-fs.target
          [Mount]
          What=/dev/disk/by-partlabel/etcd
          Where=/var/lib/etcd
          Type=xfs
          Options=defaults,noatime
          [Install]
          WantedBy=multi-user.target
EOF
echo "etcd disk MachineConfig written to SHARED_DIR"
else
    echo "No disk name provided, Skipping etcd disk MachineConfig"
fi