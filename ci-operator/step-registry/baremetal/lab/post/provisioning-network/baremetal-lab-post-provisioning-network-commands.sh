#!/bin/bash

set -o nounset

if [ ! -f "${SHARED_DIR}/provisioning_network" ]; then
  echo "No need to rollback the provisioning network. Skipping..."
  exit 0
fi

[ -z "${PROVISIONING_HOST}" ] && { echo "PROVISIONING_HOST is not filled. Failing."; exit 1; }
[ -z "${PROVISIONING_NET_DEV}" ] && { echo "PROVISIONING_NET_DEV is not filled. Failing."; exit 1; }

# As the API_VIP is unique in the managed network and based on how it is reserved in the reservation steps,
# we use the last part of it to define the VLAN ID.
# TODO: find a similar unique value for dual stack and ipv6 single stack configurations?
VLAN_ID=$(yq ".api_vip" "${SHARED_DIR}/vips.yaml")
VLAN_ID=${VLAN_ID//*\./}
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
SSH_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-key"
IFS=, read -r -a SWITCH_PORTS <<< \
  "$(yq e '[.[].switch_port_v2]|@csv' < "${SHARED_DIR:-.}"/hosts.yaml),$(<"${CLUSTER_PROFILE_DIR}/other-switch-ports")"

echo "[INFO] Configuring the VLAN tags on the switches' ports"
python3 - \
  "${SSH_KEY_PATH}" "${CLUSTER_NAME}" "${VLAN_ID}" "${SWITCH_PORTS[@]}" <<'EOF'
import sys
from traceback import print_exc
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
exit_code = 0

# The ports can lay on different switches stacks, and we cannot make a unique transaction to change their conf.
# This script is also executed as a rollback mechanism in the case a previous transaction failed. So we need to ensure
# the execution of all the transactions, regardless of exceptions being raised.
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
    try:
        print(f"Configuring switch {switch_address}")
        # Split the switch address from the form $switch1:$port
        switch_hostname = switch_address.split(":")[0]
        switch_port = switch_address.split(":")[1]
        with Device(host=switch_hostname, port=switch_port, user='admin', ssh_private_key_file=ssh_key_path) as dev:
            with Config(dev, mode="private") as cu:
                for port in switches[switch_address]:
                    print(f"Configuring port {port}")
                    # Delete the membership to the vlan in the given port
                    cu.load(
                        f"delete interfaces {port[1:] if port.startswith('T') else port} unit 0 family ethernet-switching vlan members {vlan_name}",
                        format="set", ignore_warning=True
                    )
                    # If the port is not a trunk port, we add a default vlan tag
                    if not port.startswith("T"):
                        cu.load(
                            f"set interfaces {port} unit 0 family ethernet-switching vlan members 1010",
                            format="set"
                        )
                # We finally delete the vlan and commit
                cu.load(f"delete vlans {vlan_name}", ignore_warning=True)
                cu.pdiff()
                cu.commit(force_sync=True, sync=True, timeout=300, detail=True)
                print(f"VLAN {vlan_name} ({vlan_id}) removed on {switch_address}")
    except Exception as e:
        exit_code = 1
        print(f"[ERROR] while removing VLAN {vlan_name} ({vlan_id}) on {switch_address}: {e}")
        print_exc()

if not exit_code == 0:
    print("[WARNING] Some errors occurred when rolling back the switches configuration.")
    sys.exit(exit_code)

print("All the switches have been configured")

EOF

NMSTATE_CONFIG="
interfaces:
- name: br-${CLUSTER_NAME: -12}
  type: linux-bridge
  state: absent
- name: ${PROVISIONING_NET_DEV}.${VLAN_ID}
  type: vlan
  state: absent
"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "[INFO] Rolling back the provisioning network configuration via the NMState specs"
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "'${NMSTATE_CONFIG}'"  << 'EOF'
echo "$1" | nmstatectl apply -
EOF

ret=$?
echo "[INFO] Rolling back the provisioning network configuration via the NMState specs: Done"
echo "Exit code: $ret"
exit $ret
