#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/manifest_etcd-on-ramfs-mc.yml" << EOF
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: etcd-on-ramfs
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: "${IGNITIONVERSION}"
    systemd:
      units:
        - contents: |
            [Unit]
            Description=Mount etcd as a ramdisk
            Before=local-fs.target
            [Mount]
            What=none
            Where=/var/lib/etcd
            Type=tmpfs
            Options=size=2G
            [Install]
            WantedBy=local-fs.target
          name: var-lib-etcd.mount
          enabled: true
EOF