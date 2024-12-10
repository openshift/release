#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${ENABLE_PROVISIONING_NETWORK:-true}" != "true" ]; then
  echo "The provisioning network is not enabled. Skipping..."
  exit 0
fi

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

# Use the last octet of the first master node as the VLAN ID to keep it unique in the managed network
VLAN_ID=$(yq '.[] | select(.name|test("master-00")).ip' "${SHARED_DIR}/hosts.yaml")
VLAN_ID=${VLAN_ID//*\./}
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
SSH_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-key"
IFS=, read -r -a SWITCH_PORTS <<< \
  "$(yq e '[.[].switch_port_v2]|@csv' < "${SHARED_DIR}"/hosts.yaml),$(<"${CLUSTER_PROFILE_DIR}/other-switch-ports")"

# Copy other_switch_ports to bastion host for use in cleanup
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/other-switch-ports" "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/"

echo "[INFO] Configuring the VLAN tags on the switches' ports"
python3 - \
  "${SSH_KEY_PATH}" "${CLUSTER_NAME}" "${VLAN_ID}" "${SWITCH_PORTS[@]}" <<'EOF'

import sys
from jnpr.junos import Device
from jnpr.junos.utils.config import Config

# Usage: script.py <path_to_ssh_key> <vlan_name> <vlan_id> <ports>...
# Switches ports references are in the form [T]?ge-0/0/0@switch1:22.
# Prepend a T to the reference for specifying a trunk port (e.g. Tge-0/0/0@switch1:22)
# example: script.py path/to/my-ssh-key.pem my_vlan 1001 ge-0/0/47@switch_1:22

ssh_key_path = sys.argv[1]
vlan_name = sys.argv[2]
vlan_id = sys.argv[3]
ports = sys.argv[4:]

# The ports can lay on different switches stacks, and we cannot make a unique transaction to change their conf.
# However, the rollback mechanism of the tests in Prow will take care of reverting the changes in the post steps.
# and we can safely change the configuration of each switch independently.

if not vlan_id.isdigit():
  print(f"The vlan_id is not an integer: {vlan_id}. Verify that the reservation step allocated VIPs for the cluster (use RESERVE_BOOTSTRAP: 'false' in your test config)")
  sys.exit(1)

# Let's group the ports by switch stack in a dictionary
switches = {}
for port in ports:
    # The port reference is in the form [T]?ge-0/0/0@switch1:22
    switch_network_address = port.split("@")[1]
    if switch_network_address not in switches:
        switches[switch_network_address] = []
    switches[switch_network_address].append(port.split("@")[0])

print(f"Switches to configure: {switches}")
# A transaction for each switch stack
for switch_address in switches:
    print(f"Configuring switch {switch_address}")
    # Split the switch address from the form $switch1:$port
    switch_hostname = switch_address.split(":")[0]
    switch_port = switch_address.split(":")[1]
    with Device(host=switch_hostname, port=switch_port, user='admin', ssh_private_key_file=ssh_key_path) as dev:
        with Config(dev, mode="private") as cu:
            print(f"Create the vlan {vlan_name} vlan-id {vlan_id}")
            # Create the vlan
            cu.load(f"set vlans {vlan_name} vlan-id {vlan_id}")
            for port in switches[switch_address]:
                print(f"Configuring port {port}")
                # If the port is a not a trunk port, we need to delete the previous vlan configuration first
                if not port.startswith("T"):
                    cu.load(
                        f"delete interfaces {port} unit 0 family ethernet-switching vlan members",
                        format="set", ignore_warning=True
                    )
                # Add the vlan to the port
                cu.load(
                    f"set interfaces {port[1:] if port.startswith('T') else port} unit 0 family ethernet-switching vlan members {vlan_name}",
                    format="set"
                )
            cu.pdiff()
            cu.commit(force_sync=True, sync=True, timeout=300, detail=True)
            print(f"VLAN {vlan_name} ({vlan_id}) configured on {switch_address}")

print("All the switches have been configured")

EOF


# NMState-based configuration in the provisioning host
# We are going to consider:
# - one bastion/auxiliary host that is in charge of maintaining the VNFs required to run the infrastructure
# - one provisioning host that is the target executor of the installation process and where we configure the provisioning network.
# The provisioning host and the bastion/auxiliary host may be the same host.
# The provisioning host's instruction set architecture must match the one of the cluster nodes and is not supported for
# multi-arch compute nodes scenarios yet.

# The provisioning network is configured in the jump host using NMState.
# In particular, a the network provisioning bridge is created and the vlan-tagged virtual provisioning interface is added to it.
# The provisioning bridge is connected to the provisioning interface of the provisioning host.
PROVISIONING_BRIDGE="br-${CLUSTER_NAME: -12}"
echo "${PROVISIONING_BRIDGE}" > "${SHARED_DIR}/provisioning_bridge"
PROVISIONING_NETWORK="172.22.${VLAN_ID}.0/24"
echo "${PROVISIONING_NETWORK}" > "${SHARED_DIR}/provisioning_network"
NMSTATE_CONFIG="
interfaces:
- name: ${PROVISIONING_BRIDGE}
  type: linux-bridge
  state: up
  ipv4:
    enabled: true
    auto-dns: false
    auto-gateway: false
    address:
    - ip: ${PROVISIONING_NETWORK%.*}.254
      prefix-length: ${PROVISIONING_NETWORK##*/}
  ipv6:
    enabled: true
    autoconf: false
    dhcp: false
    auto-dns: false
    auto-gateway: false
    address:
    - ip: fd00:1101:${VLAN_ID}::1
      prefix-length: 64
  bridge:
    options:
      stp:
        enabled: false
    port:
    - name: prov.${VLAN_ID}
    # TODO verify
- name: prov.${VLAN_ID}
  type: vlan
  state: up
  vlan:
    base-iface: $(<"${CLUSTER_PROFILE_DIR}/provisioning-net-dev-${architecture}")
    id: ${VLAN_ID}
"

echo "[INFO] Configuring the provisioning network in the provisioning host via the NMState specs: "
echo "${NMSTATE_CONFIG}" | tee "${ARTIFACT_DIR}/nmstate-provisioning-net-config.yaml"

timeout -s 9 10m ssh "${SSHOPTS[@]}" -p "$(sed 's/^[%]\?\([0-9]*\)[%]\?$/\1/' < "${CLUSTER_PROFILE_DIR}/provisioning-host-ssh-port-${architecture}")" "root@${AUX_HOST}" bash -s -- \
  "'${NMSTATE_CONFIG}'" "br-${CLUSTER_NAME: -12}"  << 'EOF'

echo "$1" | nmstatectl apply -
# nmstate doesn't support the firewall zone configuration yet, so we need to configure it differently
# see nmstate/nmstate#1837
nmcli conn modify "$2" connection.zone internal

EOF
echo "[INFO] Configuring the provisioning network in the provisioning host via the NMState specs: Done"
