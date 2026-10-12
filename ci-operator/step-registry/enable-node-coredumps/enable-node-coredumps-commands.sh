#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Create a machine config that installs a systemd unit on nodes. The systemd unit configures the nodes to save any
# coredumps that are generated, which will be collected during the gather-extra step.

echo "Creating manifests to enable coredump collection on nodes"

for role in master worker; do
cat > "${SHARED_DIR}/manifest_enable_node_coredumps_machineconfig_${role}.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $role
  name: enable-node-coredumps-${role}
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - contents: |
          [Unit]
          After=multi-user.target

          [Service]
          Type=oneshot
          ExecStart=sysctl -w fs.suid_dumpable=1

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: enable-node-coredumps.service
EOF
echo "manifest_enable_node_coredumps_machineconfig_${role}.yaml"
echo "---------------------------------------------"
cat ${SHARED_DIR}/manifest_enable_node_coredumps_machineconfig_${role}.yaml
done
