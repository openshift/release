#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

STARGZ_VERSION="${STARGZ_VERSION:-v0.18.2}"
STARGZ_URL="https://github.com/containerd/stargz-snapshotter/releases/download/${STARGZ_VERSION}/stargz-snapshotter-${STARGZ_VERSION}-linux-amd64.tar.gz"

echo "Injecting manifest to install stargz-store ${STARGZ_VERSION} on worker nodes"

cat > "${SHARED_DIR}/manifest_stargz_store_machineconfig_worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: stargz-store-worker
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=install stargz-store
          After=network-online.target
          Wants=network-online.target
          Before=machine-config-daemon-firstboot.service
          Before=kubelet.service

          [Service]
          Type=oneshot
          ExecStart=rpm-ostree usroverlay
          ExecStart=/usr/bin/bash -c "curl -sL ${STARGZ_URL} | tar -C /usr/local/bin -xzf - stargz-store && restorecon /usr/local/bin/stargz-store"
          RemainAfterExit=yes

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: install-stargz-store.service
EOF

echo "manifest_stargz_store_machineconfig_worker.yaml"
echo "---------------------------------------------"
cat "${SHARED_DIR}/manifest_stargz_store_machineconfig_worker.yaml"
