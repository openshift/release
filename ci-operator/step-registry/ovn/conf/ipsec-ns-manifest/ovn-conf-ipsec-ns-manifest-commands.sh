#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

for role in master worker; do
cat >> "${SHARED_DIR}/manifest_${role}-ipsec-extension.yml" <<-EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $role
  name: 80-$role-extensions
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - name: ipsecenabler.service
        enabled: true
        contents: |
         [Unit]
         Description=Enable ipsec service after os extension installation
         Before=kubelet.service

         [Service]
         Type=oneshot
         ExecStart=systemctl enable --now ipsec.service

         [Install]
         WantedBy=multi-user.target
  extensions:
    - ipsec
EOF
done
