#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Use v2 annotation names on OCP 4.22+ where CRI-O supports them.
# Older CRI-O hard-rejects unknown allowed_annotations, so fall back to v1.
# Use the initial release for upgrade jobs, since that is what the
# MachineConfig is applied on.
release_image="${RELEASE_IMAGE_INITIAL:-${RELEASE_IMAGE_LATEST}}"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" /tmp/pull-secret
KUBECONFIG="" oc registry login --to /tmp/pull-secret
ocp_version="$(oc adm release info --registry-config /tmp/pull-secret "${release_image}" -o jsonpath='{.metadata.version}')"
rm /tmp/pull-secret
major="${ocp_version%%.*}"; minor="${ocp_version#*.}"; minor="${minor%%.*}"
if (( major > 4 || (major == 4 && minor >= 22) )); then
  devices_ann="devices.crio.io"
  linklogs_ann="link-logs.crio.io"
else
  devices_ann="io.kubernetes.cri-o.Devices"
  linklogs_ann="io.kubernetes.cri-o.LinkLogs"
fi

cat > "/tmp/50-crun" << EOF
[crio.runtime]
default_runtime = "crun"
[crio.runtime.runtimes.crun]
runtime_root = "/run/crun"
allowed_annotations = [
	"io.containers.trace-syscall",
	"${devices_ann}",
	"${linklogs_ann}",
]
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
