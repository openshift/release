#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/manifest_master_coredumps.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-ocp-master-coredumps
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            compression: ""
            source: data:,fs.suid_dumpable%3D1
          path: /etc/sysctl.d/90-coredumps.conf
EOF

cat >> "${SHARED_DIR}/manifest_worker_coredumps.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-ocp-worker-coredumps
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            compression: ""
            source: data:,fs.suid_dumpable%3D1
          path: /etc/sysctl.d/90-coredumps.conf
EOF
