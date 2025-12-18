#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf nmstate-brex-bond command ************"

if [ -f "${SHARED_DIR}/dev-scripts-additional-config" ]; then
    echo "Loading existing dev-scripts configuration..."
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/dev-scripts-additional-config"
fi

NUM_MASTERS="${NUM_MASTERS:-3}"
NUM_WORKERS="${NUM_WORKERS:-3}"

generate_nmstate_machineconfigs() {
    local output_dir="${1:-/tmp/nmstate-brex-bond}"
    local master_bond_port2="${2:-enp6s0}"
    local worker_bond_port2="${3:-enp6s0}"
    local master_mac_from="${4:-enp6s0}"
    local worker_mac_from="${5:-enp6s0}"

    mkdir -p "${output_dir}/assets"
    mkdir -p "${output_dir}/network-config"

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
    cat > "${output_dir}/assets/00-generated-nmstate-brex-bond-master.yaml" <<EOF
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

    cat > "${output_dir}/assets/00-generated-nmstate-brex-bond-worker.yaml" <<EOF
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

    cat > "${output_dir}/network-config/ostest-master-0.yaml" <<EOF
networkConfig: &BOND
  interfaces:
  - name: bond0
    type: bond
    state: up
    ipv4:
      dhcp: true
      enabled: true
      auto-dns: true
      auto-gateway: true
      auto-routes: true
    link-aggregation:
      mode: active-backup
      options:
        miimon: '100'
      port:
      - enp2s0
      - ${master_bond_port2}
EOF

    for ((i=1; i<NUM_MASTERS-1; i++)); do
        cat > "${output_dir}/network-config/ostest-master-${i}.yaml" <<EOF
networkConfig: *BOND
EOF
    done

    for ((i=0; i<NUM_WORKERS-1; i++)); do
        cat > "${output_dir}/network-config/ostest-worker-${i}.yaml" <<EOF
networkConfig: *BOND
EOF
    done

    echo "Generated MachineConfigs in ${output_dir}/assets:"
    echo "  - 00-generated-nmstate-brex-bond-master.yaml"
    echo "  - 00-generated-nmstate-brex-bond-worker.yaml"
    echo "Generated network configs in ${output_dir}/network-config:"
    echo "  - ostest-master-{0...${NUM_MASTERS-1}.yaml"
    echo "  - ostest-worker-{0...${NUM_WORKERS-1}.yaml"
    echo "ASSETS_EXTRA_FOLDER=${output_dir}/assets" >> "${SHARED_DIR}/dev-scripts-additional-config"
    echo "NETWORK_CONFIG_FOLDER=${output_dir}/network-config" >> "${SHARED_DIR}/dev-scripts-additional-config"
    echo "--- Generated config in: 00-generated-nmstate-brex-bond-master.yaml ---"
    echo $master_nmstate_config
    echo "--- Generated config in: 00-generated-nmstate-brex-bond-worker.yaml ---"
    echo $worker_nmstate_config
    echo "--- Generated assets config: ---"
    echo "networkConfig: &BOND
            interfaces:
            - name: bond0
              type: bond
              state: up
              ipv4:
                dhcp: true
                enabled: true
                auto-dns: true
                auto-gateway: true
                auto-routes: true
              link-aggregation:
                mode: active-backup
                options:
                  miimon: '100'
                port:
                - enp2s0
                - ${master_bond_port2}"
}

echo "NETWORK_TYPE=\"OVNKubernetes\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "BOND_PRIMARY_INTERFACE=true" >> "${SHARED_DIR}/dev-scripts-additional-config"
#echo "EXTRA_NETWORK_NAMES=\"nmstate1 nmstate2\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
#echo "NMSTATE1_NETWORK_SUBNET_V4=\"192.168.221.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
#echo "NMSTATE1_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:ca56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
#echo "NMSTATE2_NETWORK_SUBNET_V4=\"192.168.222.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
#echo "NMSTATE2_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:cc56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"

# Generate the MachineConfig YAMLs with default parameters
generate_nmstate_machineconfigs
