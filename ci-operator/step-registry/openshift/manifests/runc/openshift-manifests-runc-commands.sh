#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Use v2 annotation names on OCP 4.22+ where CRI-O supports them.
# Older CRI-O hard-rejects unknown allowed_annotations, so fall back to v1.
release_image="${RELEASE_IMAGE_INITIAL:-${RELEASE_IMAGE_LATEST}}"
ocp_version="$(oc adm release info "${release_image}" -o jsonpath='{.metadata.version}')"
major="${ocp_version%%.*}"; minor="${ocp_version#*.}"; minor="${minor%%.*}"
if (( major > 4 || (major == 4 && minor >= 22) )); then
  devices_ann="devices.crio.io"
  linklogs_ann="link-logs.crio.io"
else
  devices_ann="io.kubernetes.cri-o.Devices"
  linklogs_ann="io.kubernetes.cri-o.LinkLogs"
fi

cat > "/tmp/50-runc" << EOF
[crio.runtime]
default_runtime = "runc"
[crio.runtime.runtimes.runc]
runtime_root = "/run/runc"
allowed_annotations = [
	"io.containers.trace-syscall",
	"${devices_ann}",
	"${linklogs_ann}",
]
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
