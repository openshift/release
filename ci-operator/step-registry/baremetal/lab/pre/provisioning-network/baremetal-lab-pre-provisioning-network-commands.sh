#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${ENABLE_PROVISIONING_NETWORK:-true}" != "true" ]; then
  echo "The provisioning network is not enabled. Skipping..."
  exit 0
fi

# As the API_VIP is uniq in the managed network and based on how it is reserved in the reservation steps,
# we use the last part of it to define the VLAN ID.
# TODO: find a similar uniq value for dual stack and ipv6 single stack configurations?
VLAN_ID=$(yq ".api_vip" "${SHARED_DIR}/vips.yaml")
VLAN_ID=${VLAN_ID//*\./}

python3 - \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_host)" \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_port)" \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_user)" \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_pass)" \
    "$(<"${SHARED_DIR}/cluster_name")" "${VLAN_ID}" \
    "$(yq e '[.[].switch_port]|@csv' < "${SHARED_DIR}"/hosts.yaml)" - <<EOF
#!/bin/python3
import os
import sys
from jnpr.junos import Device
from jnpr.junos.utils.config import Config

# example values
# vlan_name = "my_vlan2"
# vlan_id = "1001"
# interfaces = [ "ge-0/0/47", "ge-0/0/46" ]
vlan_name = sys.argv[5]
vlan_id = sys.argv[6]
interfaces = sys.argv[7].split(",")

with Device(host=sys.argv[1], port=sys.argv[2], user=sys.argv[3], password=sys.argv[4]) as dev:
    with Config(dev, mode='private') as cu:
      cu.load(f'set vlans {vlan_name} vlan-id {vlan_id}')
      cu.load(f'set interfaces ge-0/0/0 unit 0 family ethernet-switching vlan members {vlan_name}', format='set')
      for interface in interfaces:
        cu.load(f'delete interfaces {interface} unit 0 family ethernet-switching vlan members', format='set', ignore_warning=True)
        cu.load(f'set interfaces {interface} unit 0 family ethernet-switching vlan members {vlan_name}', format='set')
      cu.pdiff()
      cu.commit(force_sync=True, sync=True, timeout=300, detail=True)

EOF
