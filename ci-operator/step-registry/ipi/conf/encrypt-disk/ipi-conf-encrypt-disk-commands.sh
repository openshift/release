#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source ${SHARED_DIR}/encrypt_disk.sh


echo "$(date -u --rfc-3339=seconds) - Manifests to encrypt the disk for root partition for all nodes ..."

cat > "${SHARED_DIR}/manifest_encrypt-disk-master.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-encrypt-disk-master
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      filesystems:
        - device: /dev/mapper/root
          format: xfs
          label: root
          wipeFilesystem: true
      luks:
        - clevis:
            tpm2: true
          device: /dev/disk/by-partlabel/root
          label: luks-root
          name: root
          wipeVolume: true
EOF

cat > "${SHARED_DIR}/manifest_encrypt-disk-worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 98-encrypt-disk-worker
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      filesystems:
        - device: /dev/mapper/root
          format: xfs
          label: root
          wipeFilesystem: true
      luks:
        - clevis:
            tpm2: true
          device: /dev/disk/by-partlabel/root
          label: luks-root
          name: root
          wipeVolume: true
EOF
