#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Two-cluster support: CLUSTER_ROLE=infra redirects to the infra lease and a
# separate SHARED_DIR subdirectory so mgmt and infra files never collide.
if [[ "${CLUSTER_ROLE:-mgmt}" == "infra" ]]; then
  LEASED_RESOURCE="${LEASED_RESOURCE_INFRA}"
  SHARED_DIR="${SHARED_DIR}/infra"
  mkdir -p "${SHARED_DIR}"
fi

if [[ "${USE_RAMFS:=false}" == "true" ]]; then

echo "Creating the manifest_etcd-on-ramfs-mc.yml file..."
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
            After=ostree-remount.service var.mount
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

fi
