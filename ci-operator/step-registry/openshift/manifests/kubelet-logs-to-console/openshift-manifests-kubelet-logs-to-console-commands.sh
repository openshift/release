#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/manifest_mc-master-kubelet-console.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-kubelet-to-console
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - name: kubelet.service
        dropins:
        - name: 30-log-kubelet-to-console.conf
          contents: |
            [Service]
            StandardOutput=journal+console
EOF

sed 's;master;worker;g' ${SHARED_DIR}/manifest_mc-master-kubelet-console.yml > ${SHARED_DIR}/manifest_mc-worker-kubelet-console.yml
