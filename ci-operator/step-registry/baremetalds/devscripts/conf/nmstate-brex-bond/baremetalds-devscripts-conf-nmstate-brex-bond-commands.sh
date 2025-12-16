#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf nmstate-brex-bond command ************"

generate_nmstate_machineconfigs() {
    local output_dir="${1:-/tmp/nmstate-brex-bond}"
    local master_bond_port2="${2:-enp1s0}"
    local worker_bond_port2="${3:-enp1s0}"
    local master_mac_from="${4:-enp2s0}"
    local worker_mac_from="${5:-enp2s0}"

    mkdir -p "${output_dir}"

    # Master node nmstate config (plain text, will be base64 encoded)
    local master_nmstate_config="interfaces:
- name: bond0
  type: bond
  state: up
  ipv4:
    enabled: false
  link-aggregation:
    mode: active-backup
    options:
      miimon: '100'
    port:
    - enp2s0
    - ${master_bond_port2}
- name: br-ex
  type: ovs-bridge
  state: up
  ipv4:
    enabled: false
    dhcp: false
  ipv6:
    enabled: false
    dhcp: false
  bridge:
    port:
    - name: bond0
    - name: br-ex
- name: br-ex
  type: ovs-interface
  copy-mac-from: ${master_mac_from}
  state: up
  ipv4:
    enabled: true
    dhcp: true
  ipv6:
    enabled: true
    dhcp: true"

    # Worker node nmstate config (plain text, will be base64 encoded)
    local worker_nmstate_config="interfaces:
- name: bond0
  type: bond
  state: up
  ipv4:
    enabled: false
  link-aggregation:
    mode: active-backup
    options:
      miimon: '100'
    port:
    - enp2s0
    - ${worker_bond_port2}
- name: br-ex
  type: ovs-bridge
  state: up
  ipv4:
    enabled: false
    dhcp: false
  ipv6:
    enabled: false
    dhcp: false
  bridge:
    port:
    - name: bond0
    - name: br-ex
- name: br-ex
  type: ovs-interface
  copy-mac-from: ${worker_mac_from}
  state: up
  ipv4:
    enabled: true
    dhcp: true
  ipv6:
    enabled: true
    dhcp: true"

    # Base64 encode the nmstate configs
    local master_b64=$(echo -n "${master_nmstate_config}" | base64 -w 0)
    local worker_b64=$(echo -n "${worker_nmstate_config}" | base64 -w 0)

    # Generate master MachineConfig
    cat > "${output_dir}/00-generated-nmstate-brex-bond-master.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 00-generated-nmstate-brex-bond-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,${master_b64}
          mode: 0644
          overwrite: true
          path: /etc/nmstate/openshift/cluster.yml
EOF

    # Generate worker MachineConfig
    cat > "${output_dir}/00-generated-nmstate-brex-bond-worker.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 00-generated-nmstate-brex-bond-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,${worker_b64}
          mode: 0644
          overwrite: true
          path: /etc/nmstate/openshift/cluster.yml
EOF

    echo "Generated MachineConfigs in ${output_dir}:"
    echo "  - 00-generated-nmstate-brex-bond-master.yaml"
    echo "  - 00-generated-nmstate-brex-bond-worker.yaml"
    echo "ASSETS_EXTRA_FOLDER=${output_dir}" >> "${SHARED_DIR}/dev-scripts-additional-config"
}

echo "NETWORK_TYPE=\"OVNKubernetes\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NETWORK_CONFIG_FOLDER=/root/dev-scripts/network-configs/bond" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "BOND_PRIMARY_INTERFACE=true" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "EXTRA_NETWORK_NAMES=\"nmstate1 nmstate2\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE1_NETWORK_SUBNET_V4=\"192.168.221.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE1_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:ca56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE2_NETWORK_SUBNET_V4=\"192.168.222.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE2_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:cc56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"

# Generate the MachineConfig YAMLs with default parameters
generate_nmstate_machineconfigs
