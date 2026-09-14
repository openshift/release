#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${MULTI_NIC_IPI:-}" != "true" ]]; then
  echo "$(date -u --rfc-3339=seconds) - MULTI_NIC_IPI is not enabled, skipping secondary NIC network config"
  exit 0
fi

# vSphere assigns predictable PCI slots (192, 224, ...) to successive vmxnet3
# NICs, and MULTI_NIC_IPI always attaches exactly two networks (see
# ipi-conf-vsphere-check-vcm-commands.sh), so the secondary interface is
# always ens224. It receives a DHCP lease just like the primary (ens192), and
# without this profile that lease can install a competing default route and
# extra DNS servers, causing ambiguous address selection and NetworkManager
# reverse-DNS hostname churn during bootstrap/scale-up.
SECONDARY_NIC="ens224"

nm_config=$(cat <<EOF | base64 -w0
[connection]
id=${SECONDARY_NIC}-secondary-no-default
type=ethernet
interface-name=${SECONDARY_NIC}
autoconnect=true
autoconnect-priority=-999

[ipv4]
method=auto
never-default=true
ignore-auto-dns=true
route-metric=1024

[ipv6]
method=auto
never-default=true
ignore-auto-dns=true
route-metric=1024
EOF
)

for role in master worker; do
  cat <<EOF > "${SHARED_DIR}/manifest_${role}-multi-nic-secondary-network.yaml"
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: 98-${role}-multi-nic-secondary-network
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${nm_config}
        mode: 0600
        overwrite: true
        path: /etc/NetworkManager/system-connections/${SECONDARY_NIC}-secondary.nmconnection
EOF
  echo "$(date -u --rfc-3339=seconds) - wrote ${SHARED_DIR}/manifest_${role}-multi-nic-secondary-network.yaml"
  cat "${SHARED_DIR}/manifest_${role}-multi-nic-secondary-network.yaml"
done
