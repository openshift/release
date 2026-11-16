#!/bin/bash
set -euo pipefail

case "${NODE_ROLE}" in
  control-plane|worker|infra) ;;
  *) echo 'NODE_ROLE must be control-plane, worker, or infra' >&2; exit 1 ;;
esac
if [[ ! "${ADDITIONAL_NODES}" =~ ^[1-9][0-9]*$ ]] || (( ${#ADDITIONAL_NODES} > 3 )) || (( ADDITIONAL_NODES > 244 )); then
  echo 'ADDITIONAL_NODES must be a positive integer within the VM subnet capacity' >&2
  exit 1
fi

SSHOPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
workdir=$(cat "${SHARED_DIR}/remote_workdir")

ssh "${SSHOPTS[@]}" "${remote}" sudo bash -s -- "${workdir}" "${NODE_ROLE}" "${ADDITIONAL_NODES}" <<'REMOTE'
set -euo pipefail
umask 077
cd "$1"
trap 'chown -R ec2-user:ec2-user .' EXIT
node_role=$2
additional_nodes=$3
# shellcheck source=/dev/null
source common.sh
cluster_domain=$(jq -er .clusterDomain state.json)
network=$(jq -er .network state.json)
[[ "${network}" == topology-transition ]]

# Check the whole batch before changing DHCP, disks, or inventory.
oc get nodes -o json > existing-nodes.json
python3 - "${node_role}" "${additional_nodes}" <<'PY'
import ipaddress
import json
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET

role, count = sys.argv[1], int(sys.argv[2])
inventory = json.loads(pathlib.Path('inventory.json').read_text())
existing_nodes = json.loads(pathlib.Path('existing-nodes.json').read_text())
state = json.loads(pathlib.Path('state.json').read_text())
subnet = ipaddress.ip_network(state['cidr'])
image_dir = pathlib.Path(state['imageDirectory'])
used_names = {node['metadata']['name'] for node in existing_nodes['items']}
used_ips, used_macs = set(), set()

for node in inventory:
    used_names.add(node['name'])
    used_ips.add(node['ip'])
    used_macs.add(node['mac'].lower())

for kind, listing, dump in [('net', 'net-list', 'net-dumpxml'), ('vm', 'list', 'dumpxml')]:
    names = subprocess.check_output(['virsh', listing, '--all', '--name'], text=True).split()
    for name in names:
        root = ET.fromstring(subprocess.check_output(['virsh', dump, name], text=True))
        if kind == 'vm':
            used_names.add(name)
        for element in root.iter():
            if element.tag == 'mac' and element.get('address'):
                used_macs.add(element.get('address').lower())
            if element.get('mac'):
                used_macs.add(element.get('mac').lower())
            if element.get('ip'):
                used_ips.add(element.get('ip'))
            if element.get('name'):
                used_names.add(element.get('name'))
            if element.tag == 'hostname' and element.text:
                used_names.add(element.text.split('.')[0])

next_ip = max(int(ipaddress.ip_address(node['ip'])) for node in inventory) + 1
if next_ip + count > int(subnet.broadcast_address):
    sys.exit('Not enough IPs in the VM subnet')

planned = []
for index in range(next_ip, next_ip + count):
    name = ('master' if role == 'control-plane' else role) + '-' + str(index - int(subnet.network_address) - 10)
    ip = str(ipaddress.ip_address(index))
    mac = f'52:54:00:7a:00:{index - int(subnet.network_address):02x}'
    if (name in used_names or ip in used_ips or mac in used_macs or
            any((image_dir / (name + suffix)).exists() for suffix in ['.iso', '.qcow2'])):
        sys.exit('Requested VM resources overlap existing names, IPs, MACs, or disks')
    planned.append(dict(name=name, ip=ip, mac=mac, role=role))

pathlib.Path('expected-nodes.json').write_text(json.dumps(planned, indent=2) + '\n')
PY

# Trust the running MCS CA, rather than an expired install-time Ignition token.
oc -n openshift-machine-config-operator get configmap machine-config-server-ca \
  -o jsonpath='{.data.ca-bundle\.crt}' > mcs-ca.crt
[[ -s mcs-ca.crt ]]
ignition_role=worker
kube_role=worker
if [[ "${node_role}" == control-plane ]]; then
  ignition_role=master
  kube_role=master
fi
jq -n --arg ca "data:text/plain;charset=utf-8;base64,$(base64 -w0 mcs-ca.crt)" \
  --arg url "https://api-int.${cluster_domain}:22623/config/${ignition_role}" \
  '{ignition:{version:"3.2.0",security:{tls:{certificateAuthorities:[{source:$ca}]}},config:{merge:[{source:$url}]}}}' > join.ign

# The live image installs to disk and reboots into the node Ignition.
while IFS=$'\t' read -r name ip mac; do
  jq --arg hostname "data:;base64,$(printf '%s\n' "${name}" | base64 -w0)" '
    .storage.files = [{path:"/etc/hostname",mode:420,overwrite:true,contents:{source:$hostname}}]' join.ign > "${name}.ign"
  jq -n --arg ignition "data:;base64,$(base64 -w0 "${name}.ign")" \
    '{ignition:{version:"3.2.0"},storage:{files:[{path:"/etc/node.ign",mode:384,contents:{source:$ignition}}]},
      systemd:{units:[{name:"install-node.service",enabled:true,contents:
      "[Unit]\nWants=network-online.target\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/bin/coreos-installer install /dev/vda --ignition-file /etc/node.ign\nExecStartPost=/usr/bin/systemctl reboot\n[Install]\nWantedBy=multi-user.target\n"}]}}' > "${name}-install.ign"
  jq --arg name "${name}" --slurpfile planned expected-nodes.json \
    '. + [$planned[0][] | select(.name == $name)]' inventory.json > inventory.next.json
  mv inventory.next.json inventory.json
  create_vm "${name}" "${mac}" "${ip}" "${name}-install.ign"
done < <(jq -r '.[] | [.name,.ip,.mac] | @tsv' expected-nodes.json)
refresh_load_balancer
wait_for_nodes "${kube_role}"
if [[ "${node_role}" == infra ]]; then
  # Infra uses worker Ignition. Placement and taint policy belong to the caller.
  mapfile -t infra_nodes < <(jq -r '.[].name' expected-nodes.json)
  oc label nodes "${infra_nodes[@]}" node-role.kubernetes.io/infra= --overwrite
  wait_for_nodes infra
fi
cp expected-nodes.json "added-${node_role}-$(date +%s).json"
REMOTE

scp "${SSHOPTS[@]}" "${remote}:${workdir}/inventory.json" "${SHARED_DIR}/topology-inventory.json"
scp "${SSHOPTS[@]}" "${remote}:${workdir}/expected-nodes.json" "${SHARED_DIR}/topology-added-${NODE_ROLE}.json"
