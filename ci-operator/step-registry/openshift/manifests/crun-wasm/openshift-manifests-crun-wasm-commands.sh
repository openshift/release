#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat > "/tmp/99-crun-wasm.conf" << EOF
[crio.runtime]
default_runtime = "crun-wasm"
[crio.runtime.runtimes.crun-wasm]
runtime_path = "/usr/bin/crun"
platform_runtime_paths = {"wasi/wasm32" = "/usr/bin/crun-wasm"}
EOF

cat > "${SHARED_DIR}/manifest_mc-master-crun-wasm.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-crun-wasm
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,$(base64 -w0 </tmp/99-crun-wasm.conf)
        filesystem: root
        mode: 0644
        path: /etc/crio/crio.conf.d/99-crun-wasm.conf
  extensions:
    - wasm
EOF

sed 's/master/worker/g' "${SHARED_DIR}/manifest_mc-master-crun-wasm.yml" > "${SHARED_DIR}/manifest_mc-worker-crun-wasm.yml"
