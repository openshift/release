#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

if [[ -n "${WORKER_POD_DISK_NAME}" ]]; then
cat > "${SHARED_DIR}/manifest_98-worker-pod-local-${WORKER_POD_DISK_NAME}.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 98-worker-pod-local-${WORKER_POD_DISK_NAME}
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      disks:
      - device: /dev/${WORKER_POD_DISK_NAME}
        wipeTable: true
        partitions:
        - label: worker-pod
          number: 1
      filesystems:
      - device: /dev/disk/by-partlabel/worker-pod
        format: xfs
        mountOptions:
        - defaults
        - prjquota
        path: /var/lib/containers
        wipeFilesystem: true
    systemd:
      units:
      - name: var-lib-containers.mount
        enabled: true
        contents: |
          [Unit]
          Description=Mount Local NVMe (${WORKER_POD_DISK_NAME}) for worker pod storage
          After=ostree-remount.service var.mount
          Before=local-fs.target
          [Mount]
          What=/dev/disk/by-partlabel/worker-pod
          Where=/var/lib/containers
          Type=xfs
          Options=defaults,prjquota,noatime
          [Install]
          WantedBy=local-fs.target
EOF
echo "Worker pod disk MachineConfig written to SHARED_DIR"
else
    echo "No disk name provided, Skipping worker pod disk MachineConfig"
fi