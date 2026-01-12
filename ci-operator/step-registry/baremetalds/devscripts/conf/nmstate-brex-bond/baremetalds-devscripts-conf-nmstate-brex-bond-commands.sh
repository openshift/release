#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf nmstate-brex-bond command ************"

generate_nmstate_machineconfigs() {
  if [ -n "${DEVSCRIPTS_CONFIG:-}" ]; then
    echo "Applying DEVSCRIPTS_CONFIG environment variables..."
    while IFS= read -r line; do
      if [ -n "$line" ] && [[ ! "$line" =~ ^[[:space:]]*# ]]; then
        echo "  Setting: $line"
        export "$line"
      fi
    done <<< "$DEVSCRIPTS_CONFIG"
    echo "*******************************************************************************"
  fi

  local master_bond_port1="${NMS_BREX_MASTER_NIC1:-"enp2s0"}"
  local worker_bond_port1="${NMS_BREX_WORKER_NIC1:-$master_bond_port1}"
  local master_bond_port2="${NMS_BREX_MASTER_NIC2:-"enp3s0"}"
  local worker_bond_port2="${NMS_BREX_WORKER_NIC2:-$master_bond_port2}"
  local master_mac_from="${NMS_BREX_MASTER_COPY_MAC_FROM:-$master_bond_port1}"
  local worker_mac_from="${NMS_BREX_WORKER_COPY_MAC_FROM:-$worker_bond_port1}"

  local masters="${NUM_MASTERS:-3}"
  local workers="${NUM_WORKERS:-3}"

  local ipv4_enabled="false"
  local ipv6_enabled="true"

  case "${IP_STACK:-v6}" in
    v4)
      ipv4_enabled="true"
      ipv6_enabled="false"
      ;;
    v4v6|v6v4)
      ipv4_enabled="true"
      ipv6_enabled="true"
      ;;
    *)
      ipv4_enabled="false"
      ipv6_enabled="true"
      ;;
  esac

  echo "IP_STACK: ${IP_STACK:-<empty>} -> IPv4: ${ipv4_enabled}, IPv6: ${ipv6_enabled}"
  echo "*******************************************************************************"

  mkdir -p "${SHARED_DIR}/nmstate-network-config"

  if [ -n "${NMS_BREX_ASSET_CONF_MASTER:-}" ]; then
    echo "Using custom NMS_BREX_ASSET_CONF for asset configuration"
    local master_nmstate_config="${NMS_BREX_ASSET_CONF_MASTER}"
    local worker_nmstate_config="${NMS_BREX_ASSET_CONF_WORKER:-NMS_BREX_ASSET_CONF_MASTER}"
  else
    echo "Generating default asset configuration"
  fi

  # Master node nmstate config (plain text, will be base64 encoded)
  if [ -z "${NMS_BREX_ASSET_CONF_MASTER:-}" ]; then
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
      primary: ${master_bond_port1}
      primary_reselect: always
    port:
    - ${master_bond_port1}
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
    enabled: ${ipv4_enabled}
    dhcp: ${ipv4_enabled}
  ipv6:
    enabled: ${ipv6_enabled}
    dhcp: ${ipv6_enabled}"

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
      primary: ${master_bond_port1}
      primary_reselect: always
    port:
    - ${worker_bond_port1}
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
    enabled: ${ipv4_enabled}
    dhcp: ${ipv4_enabled}
  ipv6:
    enabled: ${ipv6_enabled}
    dhcp: ${ipv6_enabled}"
  fi

  local master_b64
  local worker_b64
  master_b64=$(echo -n "${master_nmstate_config}" | base64 -w 0)
  worker_b64=$(echo -n "${worker_nmstate_config}" | base64 -w 0)

  cat > "${SHARED_DIR}/manifest_00-generated-nmstate-brex-bond-master.yaml" <<EOF
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

  cat > "${SHARED_DIR}/manifest_00-generated-nmstate-brex-bond-worker.yaml" <<EOF
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

  # Check if custom network config is provided
  if [ -n "${NMS_BREX_NETWORK_CONF_MASTER:-}" ]; then
    echo "Using custom NMS_BREX_NETWORK_CONF_MASTER for network configuration"
    cat > "${SHARED_DIR}/nmstate-network-config/ostest-master-0.yaml" <<EOF
${NMS_BREX_NETWORK_CONF_MASTER}
EOF
  else
    echo "Generating default network configuration"
    cat > "${SHARED_DIR}/nmstate-network-config/ostest-master-0.yaml" <<EOF
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
      - ${master_bond_port1}
      - ${master_bond_port2}
EOF
  fi

  for ((i=1; i<masters; i++)); do
    cat > "${SHARED_DIR}/nmstate-network-config/ostest-master-${i}.yaml" <<EOF
networkConfig: *BOND
EOF
  done

  for ((i=0; i<workers; i++)); do
    cat > "${SHARED_DIR}/nmstate-network-config/ostest-worker-${i}.yaml" <<EOF
networkConfig: *BOND
EOF
  done

  echo "--- Generated MachineConfigs as manifests in ${SHARED_DIR}: ---"
  echo "  - manifest_00-generated-nmstate-brex-bond-master.yaml"
  echo "  - manifest_00-generated-nmstate-brex-bond-worker.yaml"

  echo "---------- Generated network configs in ${SHARED_DIR}/nmstate-network-config: ---------"
  echo "  - ostest-master-{0...$((masters-1))}.yaml"
  echo "  - ostest-worker-{0...$((workers-1))}.yaml"

  echo "------- Generated config in: manifest_00-generated-nmstate-brex-bond-master.yaml -------"
  cat "${SHARED_DIR}/manifest_00-generated-nmstate-brex-bond-master.yaml"

  echo "------- Generated config in: manifest_00-generated-nmstate-brex-bond-worker.yaml -------"
  cat "${SHARED_DIR}/manifest_00-generated-nmstate-brex-bond-worker.yaml"

  echo "-------------------------- Generated network config: ---------------------------"
  cat "${SHARED_DIR}/nmstate-network-config/ostest-master-0.yaml"

  echo "------------------ Setting network-config path --------------------"
  echo "NETWORK_CONFIG_FOLDER=${SHARED_DIR}/nmstate-network-config" >> "${SHARED_DIR}/dev-scripts-additional-config"
}

echo "NETWORK_TYPE=\"OVNKubernetes\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "BOND_PRIMARY_INTERFACE=true" >> "${SHARED_DIR}/dev-scripts-additional-config"
generate_nmstate_machineconfigs
