#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Create CRI-O configuration to enable WASM support via platform_runtime_paths
# This configuration allows crun to automatically detect WASM workloads and use
# the appropriate runtime (crun-wasm) based on pod annotations and image platform.
#
# Key changes from previous version:
# 1. Removed `default_runtime = "crun-wasm"` to prevent breaking system containers
# 2. Configure the existing "crun" runtime instead of creating a new "crun-wasm" runtime
# 3. Use platform_runtime_paths to let crun automatically select the WASM runtime
# 4. Removed unnecessary `extensions: - wasm` (pre-installed in RHCOS 9.x)
#
# How it works:
# - Regular containers: Use /usr/bin/crun (standard OCI runtime)
# - WASM containers: Detected by pod annotation (module.wasm.image/variant: compat)
#                    or image platform (wasi/wasm32), then use /usr/bin/crun-wasm
#
# References:
# - https://github.com/containers/crun/blob/main/docs/wasm-wasi-on-kubernetes.md
# - https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md

cat > "/tmp/99-crun-wasm.conf" << EOF
[crio.runtime.runtimes.crun]
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
EOF

sed 's/master/worker/g' "${SHARED_DIR}/manifest_mc-master-crun-wasm.yml" > "${SHARED_DIR}/manifest_mc-worker-crun-wasm.yml"
