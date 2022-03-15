#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat > "/tmp/50-crun" << EOF
[crio.runtime]
default_runtime = "crun"
[crio.runtime.runtimes.crun]
runtime_root = "/run/crun"
EOF

cat > "${SHARED_DIR}/manifest_mc-master-crun.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-crun
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,$(base64 -w0 </tmp/50-crun)
        filesystem: root
        mode: 0644
        path: /etc/crio/crio.conf.d/50-crun
EOF

sed 's/master/worker/g' "${SHARED_DIR}/manifest_mc-master-crun.yml" > "${SHARED_DIR}/manifest_mc-worker-crun.yml"