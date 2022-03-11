#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail


filename="${SHARED_DIR}/manifest_single-node-workload-partitioning.yml"

# Create workload partiotioning configuration for crio
workload_partitioning=$(cat <<EOF | base64 -w 0
[crio.runtime.workloads.management]
activation_annotation = "target.workload.openshift.io/management"
annotation_prefix = "resources.workload.openshift.io"
resources = { "cpushares" = 0, "cpuset" = "0-$(( $WORKLOAD_PINNED_CORES - 1))" }
EOF
)

# Create workload pinning config for kubelet
workload_pining=$(cat <<EOF | base64 -w 0
{
  "management": {
    "cpuset": "0-$(( $WORKLOAD_PINNED_CORES - 1))"
  }
}
EOF
)

# Use first four cores on a single node for workload partitioning (see https://github.com/openshift/enhancements/blob/master/enhancements/workload-partitioning/management-workload-partitioning.md#goals)
# this is configurable via WORKLOAD_PINNED_CORES for testing with in the CI
# ... but avoid applying workload partitioning if OCP version < 4.10 (or if OCP_VERSION is not set)
REQUIRED_OCP_VERSION="4.10"
if [ "$(printf '%s\n' "${REQUIRED_OCP_VERSION}" "${OCP_VERSION}" | sort --version-sort | head -n1)" = "${REQUIRED_OCP_VERSION}" ]; then
    cat >"${filename}" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 02-master-workload-partitioning
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${workload_partitioning}
        mode: 420
        overwrite: true
        path: /etc/crio/crio.conf.d/01-workload-partitioning
        user:
          name: root
      - contents:
          source: data:text/plain;charset=utf-8;base64,${workload_pining}
        mode: 420
        overwrite: true
        path: /etc/kubernetes/openshift-workload-pinning
        user:
          name: root
EOF
  echo "Created ${filename}"
  cat ${filename}
fi
