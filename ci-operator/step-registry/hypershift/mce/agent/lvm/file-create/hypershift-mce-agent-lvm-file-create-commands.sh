#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

oc apply -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-lvm-file-setup
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: lvm-file-loop-setup.service
          enabled: true
          contents: |
            [Unit]
            Description=Allocate a 64G regular file and setup a Loop Device that targets it to be used by the LVM Operator
            After=local-fs.target

            [Service]
            Type=oneshot
            RemainAfterExit=true
            ExecStartPre=/usr/bin/bash -x -c '[ -f /var/lvm-operator-storage.lvm ] || /usr/bin/fallocate -l 64G /var/lvm-operator-storage.lvm'
            ExecStart=/usr/sbin/losetup /dev/loop0 /var/lvm-operator-storage.lvm

            [Install]
            WantedBy=multi-user.target
EOF

oc wait --for=condition=Updating --timeout=10m machineconfigpool/worker
oc wait --for=condition=Updated --timeout=30m machineconfigpool/worker

echo "/dev/loop0" > "${SHARED_DIR}/lvmdevice"
