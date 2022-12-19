#!/bin/bash

set -o nounset

if [ "${ENABLE_PROVISIONING_NETWORK:-true}" != "true" ]; then
  echo "The provisioning network is not enabled. Skipping..."
  exit 0
fi

python3 - \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_host)" \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_port)" \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_user)" \
    "$(<"${CLUSTER_PROFILE_DIR}"/switch_pass)" \
    "${NAMESPACE}" \
    "$(yq e '[.[].switch_port]|@csv' < "${SHARED_DIR}"/hosts.yaml)" <<EOF
#!/bin/python3
import os
import sys
from jnpr.junos import Device
from jnpr.junos.utils.config import Config

# example values
# vlan_name = "my_vlan2"
# interfaces = [ "ge-0/0/47", "ge-0/0/46" ]
vlan_name = sys.argv[5]
interfaces = sys.argv[6].split(",")

with Device(host=sys.argv[1], port=sys.argv[2], user=sys.argv[3], password=sys.argv[4]) as dev:
    with Config(dev, mode='private') as cu:
      cu.load(f'delete interfaces ge-0/0/0 unit 0 family ethernet-switching vlan members {vlan_name}', format='set', ignore_warning=True)
      for interface in interfaces:
          cu.load(f'delete interfaces {interface} unit 0 family ethernet-switching vlan members', format='set', ignore_warning=True)
          cu.load(f'set interfaces {interface} unit 0 family ethernet-switching vlan members vlan8', format='set')
      cu.load(f'delete vlans {vlan_name}', ignore_warning=True)
      cu.pdiff()
      cu.commit(force_sync=True, sync=True, timeout=300, detail=True)

EOF
