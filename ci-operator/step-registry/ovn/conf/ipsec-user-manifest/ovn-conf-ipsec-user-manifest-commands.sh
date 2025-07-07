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
  annotations:
    user-ipsec-machine-config: "true"
  name: 80-ipsec-$role-extensions
spec:
  osImageURL: quay.io/pepalani/ipsec-rhcos-layered-image:4.20.0-0.nightly-2025-05-28-190420
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
         ExecStartPre=systemd-tmpfiles --create /usr/lib/rpm-ostree/tmpfiles.d/libreswan.conf
         ExecStart=systemctl enable --now ipsec.service

         [Install]
         WantedBy=multi-user.target
  extensions:
    - ipsec
EOF
cat ${SHARED_DIR}/manifest_${role}-ipsec-extension.yml
done


