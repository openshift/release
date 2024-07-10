#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat > "/tmp/50-runc" << EOF
[crio.runtime]
default_runtime = "runc"
[crio.runtime.runtimes.runc]
runtime_root = "/run/runc"
EOF

cat > "${SHARED_DIR}/manifest_mc-master-runc.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-runc
spec:
  config:
    ignition:
      version: 3.3.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,$(base64 -w0 </tmp/50-runc)
        filesystem: root
        mode: 0644
        path: /etc/crio/crio.conf.d/50-runc
EOF

sed 's/master/worker/g' "${SHARED_DIR}/manifest_mc-master-runc.yml" > "${SHARED_DIR}/manifest_mc-worker-runc.yml"
