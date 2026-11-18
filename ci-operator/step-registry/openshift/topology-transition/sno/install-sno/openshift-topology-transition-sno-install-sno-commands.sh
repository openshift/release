#!/bin/bash
set -euo pipefail
umask 077

# SSH requires an entry for the random UID assigned to this container.
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo '/etc/passwd is not writable, and no user exists for the current UID.' >&2
    exit 1
  fi
fi

SSHOPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
workdir="/home/$(cat "${SHARED_DIR}/ssh_user")/topology-transition"
printf '%s\n' "${workdir}" > "${SHARED_DIR}/remote_workdir"
printf '%s\n' "${workdir}/pull-secret" > "${SHARED_DIR}/pull_secret_file"

# Keep the handoff even if installation fails so post steps can gather logs.
ssh "${SSHOPTS[@]}" "${remote}" "mkdir -p '${workdir}/bin' '${workdir}/results'"
jq -cs '.[0] * .[1]' "${CLUSTER_PROFILE_DIR}/pull-secret" \
  /var/run/pull-secret/.dockerconfigjson > "${SHARED_DIR}/topology-pull-secret"
scp "${SSHOPTS[@]}" "${SHARED_DIR}/topology-pull-secret" "${remote}:${workdir}/pull-secret"
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${remote}:${workdir}/ssh-publickey"
scp "${SSHOPTS[@]}" /var/run/rhsm/subscription-manager-{org,act-key} "${remote}:${workdir}/"

# The dev-scripts image contains the source tree in its working directory.
# Follow the same source handoff as baremetalds-devscripts-setup.
[[ -f Makefile && -f agent/06_agent_create_cluster.sh ]]
tar -czf - . | ssh "${SSHOPTS[@]}" "${remote}" "cat > '${workdir}/dev-scripts.tar.gz'"

# Shared host helpers are also used by add-nodes. Inventory is recorded before boot.
cat > "${SHARED_DIR}/topology-common.sh" <<'COMMON'
set -euo pipefail
export PATH="${PWD}/bin:${PATH}"
export KUBECONFIG="${PWD}/install/auth/kubeconfig"
export REGISTRY_AUTH_FILE="${PWD}/pull-secret"
network=$(jq -er .network state.json)
cluster_domain=$(jq -er .clusterDomain state.json)
image_dir=$(jq -er .imageDirectory state.json)
gateway=$(jq -er .gateway state.json)

refresh_load_balancer() {
  {
    cat <<'CONFIG'
global
  maxconn 4000
  user haproxy
  group haproxy
defaults
  mode tcp
  timeout connect 10s
  timeout client 1m
  timeout server 1m
CONFIG
    local port
    for port in 6443 22623 80 443; do
      printf 'listen port-%s\n  bind %s:%s\n  balance roundrobin\n' "${port}" "${gateway}" "${port}"
      jq -r --arg port "${port}" '.[] | select((.role == "control-plane") or ($port == "80" or $port == "443")) |
        "  server \(.name) \(.ip):\($port) check"' inventory.json
    done
  } > haproxy.cfg

  haproxy -c -f haproxy.cfg
  install -m 644 haproxy.cfg /etc/haproxy/haproxy.cfg
  systemctl reload-or-restart haproxy
}

set_api_dns() {
  local target_ip=$1 dns_config

  dns_config=$(jq -er .dnsConfig state.json)
  [[ -f "${dns_config}" ]]

  # Keep dev-scripts node and provisioner aliases when moving host and guest DNS.
  python3 - "${network}" "${cluster_domain}" "${target_ip}" <<'API_DNS_PY'
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

network, domain, target_ip = sys.argv[1:]
aliases = ['api', 'api-int', f'api.{domain}', f'api-int.{domain}']
root = ET.fromstring(subprocess.check_output(['virsh', 'net-dumpxml', network], text=True))
target_names = []

for host in root.findall('dns/host'):
    names = [entry.text for entry in host.findall('hostname')]
    if host.get('ip') != target_ip and not any(name in aliases for name in names):
        continue

    subprocess.run(['virsh', 'net-update', network, 'delete', 'dns-host',
                    ET.tostring(host, encoding='unicode'), '--live', '--config'], check=True)
    remaining = [name for name in names if name not in aliases]
    if host.get('ip') == target_ip:
        target_names.extend(remaining)
    elif remaining:
        for entry in list(host):
            if entry.tag == 'hostname' and entry.text in aliases:
                host.remove(entry)
        subprocess.run(['virsh', 'net-update', network, 'add-last', 'dns-host',
                        ET.tostring(host, encoding='unicode'), '--live', '--config'], check=True)

host = ET.Element('host', ip=target_ip)
for name in dict.fromkeys(target_names + aliases):
    ET.SubElement(host, 'hostname').text = name
subprocess.run(['virsh', 'net-update', network, 'add-last', 'dns-host',
                ET.tostring(host, encoding='unicode'), '--live', '--config'], check=True)

# SNO adds exact route names to /etc/hosts, which take priority over DNS.
hosts_file = Path('/etc/hosts')
lines = []
for line in hosts_file.read_text().splitlines(keepends=True):
    record, marker, comment = line.partition('#')
    fields = record.split()
    matching = [name for name in fields[1:] if name.endswith('.apps.' + domain)]
    if not matching:
        lines.append(line)
        continue

    remaining = [name for name in fields[1:] if name not in matching]
    suffix = ' #' + comment.rstrip('\n') if marker else ''
    if remaining:
        lines.append(' '.join([fields[0]] + remaining) + suffix + '\n')
        suffix = ''
    lines.append(' '.join([target_ip] + matching) + suffix + '\n')
hosts_file.write_text(''.join(lines))
API_DNS_PY

  cat > "${dns_config}" <<EOF
address=/api.${cluster_domain}/${target_ip}
address=/api-int.${cluster_domain}/${target_ip}
address=/.apps.${cluster_domain}/${target_ip}
listen-address=::1
cache-size=0
EOF
  systemctl reload NetworkManager
}

create_vm() {
  local name=$1 mac=$2 ip=$3 ignition=$4
  local deadline state

  # Never remove an existing VM, disk, DHCP entry, or DNS record.
  if virsh dominfo "${name}" >/dev/null 2>&1 || [[ -e "${image_dir}/${name}.qcow2" || -e "${image_dir}/${name}.iso" ]]; then
    echo 'VM name or disk overlaps an existing resource' >&2
    return 1
  fi

  virsh net-update "${network}" add-last ip-dhcp-host \
    "<host mac='${mac}' name='${name}' ip='${ip}'/>" --live --config
  virsh net-update "${network}" add-last dns-host \
    "<host ip='${ip}'><hostname>${name}</hostname><hostname>${name}.${cluster_domain}</hostname></host>" --live --config
  qemu-img create -f qcow2 "${image_dir}/${name}.qcow2" 120G
  jq --arg hostname "data:;base64,$(printf '%s\n' "${name}" | base64 -w0)" '
    .storage.files = ((.storage.files // []) + [{path:"/etc/hostname",mode:420,overwrite:true,contents:{source:$hostname}}])' \
    "${ignition}" > "${name}-live.ign"
  # Use the same ISO tool container as baremetalds-sno-add-worker.
  podman run --rm --cgroups=disabled --privileged --security-opt label=disable -v "${PWD}:${PWD}:ro" \
    -v "${image_dir}:${image_dir}" -w "${PWD}" quay.io/coreos/coreos-installer:release \
    iso ignition embed -i "${name}-live.ign" -o "${image_dir}/${name}.iso" rhcos-live.iso
  chmod 644 "${image_dir}/${name}.iso"
  restorecon -R "${image_dir}"
  virt-install --connect qemu:///system --name "${name}" --memory 16384 --vcpus 8 \
    --cpu host-passthrough --disk "${image_dir}/${name}.qcow2,bus=virtio" \
    --network "network=${network},model=virtio,mac=${mac}" \
    --cdrom "${image_dir}/${name}.iso" --os-variant rhel9.0 --graphics none \
    --noautoconsole --boot hd,cdrom --events on_reboot=restart \
    --boot loader=/usr/share/edk2/ovmf/OVMF_CODE.fd,loader_ro=yes,loader_type=pflash,nvram_template=/usr/share/edk2/ovmf/OVMF_VARS.fd,loader_secure=no \
    --tpm none \
    --serial "file,path=/var/log/libvirt/qemu/${name}-console.log"

  # virt-install stops the live install on reboot despite on_reboot=restart.
  deadline=$((SECONDS + 1200))
  while true; do
    state=$(virsh domstate "${name}")
    [[ "${state}" != 'shut off' ]] || break

    if (( SECONDS >= deadline )); then
      echo 'Timed out waiting for the live install VM to shut off' >&2
      return 1
    fi

    sleep 10
  done

  # Boot only from the installed disk; keeping the ISO bootable can reinstall it.
  virsh dumpxml --inactive "${name}" > "${name}-disk.xml"
  python3 - "${name}-disk.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
root = tree.getroot()
os_config = root.find('os')
devices = root.find('devices')

for boot in os_config.findall('boot'):
    os_config.remove(boot)
ET.SubElement(os_config, 'boot', dev='hd')

for device in list(devices):
    if device.tag == 'disk' and device.get('device') == 'cdrom':
        devices.remove(device)
    else:
        for boot in device.findall('boot'):
            device.remove(boot)

tree.write(sys.argv[1], encoding='unicode')
PY
  virsh define "${name}-disk.xml"
  virsh start "${name}"
  [[ "$(virsh domstate "${name}")" == running ]]
}

approve_expected_csrs() {
  local csr signer username name request subject

  oc --request-timeout=30s get csr -o json > csrs.json || return 1
  while IFS=$'\t' read -r csr signer username request; do
    [[ -n "${csr}" ]] || continue
    printf '%s' "${request}" | base64 -d > csr.pem
    if ! subject=$(openssl req -in csr.pem -noout -subject -nameopt sep_multiline); then
      continue
    fi
    grep -qx ' *O=system:nodes' <<< "${subject}" || continue
    name=$(sed -n 's/^ *CN=system:node://p' <<< "${subject}")
    jq -e --arg name "${name}" 'any(.[]; .name == $name)' expected-nodes.json >/dev/null || continue

    case "${signer}:${username}" in
      kubernetes.io/kube-apiserver-client-kubelet:system:serviceaccount:openshift-machine-config-operator:node-bootstrapper|\
      "kubernetes.io/kubelet-serving:system:node:${name}")
        oc --request-timeout=30s adm certificate approve "${csr}" >/dev/null || return 1
        ;;
    esac
  done < <(jq -r '.items[] | select((.status.conditions // [] | length) == 0) |
    [.metadata.name, .spec.signerName, .spec.username, .spec.request] | @tsv' csrs.json)
}

wait_for_nodes() {
  local role=$1 deadline=$((SECONDS + 3600))

  while (( SECONDS < deadline )); do
    if ! approve_expected_csrs || ! oc --request-timeout=30s get csr -o json > csrs.json; then
      sleep 15
      continue
    fi

    if oc --request-timeout=30s get nodes -o json > nodes.json && jq -e --arg role "${role}" --slurpfile nodes nodes.json '
      all(.[]; .name as $name | any($nodes[0].items[];
        .metadata.name == $name and
        (.metadata.labels | has("node-role.kubernetes.io/" + $role)) and
        any(.status.conditions[]; .type == "Ready" and .status == "True")))
      ' expected-nodes.json >/dev/null && jq -e --slurpfile csrs csrs.json '
        all(.[]; .name as $name | any($csrs[0].items[];
          .spec.signerName == "kubernetes.io/kubelet-serving" and
          .spec.username == ("system:node:" + $name) and
          ((.status.certificate // "") | length > 0)))' expected-nodes.json >/dev/null; then
      return 0
    fi
    sleep 15
  done

  echo 'Timed out waiting for expected nodes and roles' >&2
  return 1
}
COMMON
scp "${SSHOPTS[@]}" "${SHARED_DIR}/topology-common.sh" "${remote}:${workdir}/common.sh"

# Values are passed as positional args, never expanded into generated shell code.
ssh "${SSHOPTS[@]}" "${remote}" sudo env HOME=/root bash -s -- "${workdir}" "${RELEASE_IMAGE_LATEST}" <<'REMOTE'
set -euo pipefail
umask 077
cd "$1"
trap 'chown -R ec2-user:ec2-user .' EXIT
release_image=$2
export PATH="${PWD}/bin:${PATH}"
export REGISTRY_AUTH_FILE="${PWD}/pull-secret"

subscription-manager config --rhsm.manage_repos=1
if ! subscription-manager identity >/dev/null 2>&1; then
  subscription-manager register --org="$(cat subscription-manager-org)" \
    --activationkey="$(cat subscription-manager-act-key)" >/dev/null
fi
rm -f subscription-manager-org subscription-manager-act-key
subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms --enable=rhel-9-for-x86_64-appstream-rpms
# As in baremetalds-devscripts-setup, install only the tools needed to start make.
# Dev-scripts installs the VM, network, and Agent dependencies.
for attempt in 1 2 3; do
  if dnf install -y git sysstat sos make podman python3 jq net-tools gcc \
    dnf-plugins-core haproxy policycoreutils-python-utils openssl; then
    break
  fi
  [[ ${attempt} -lt 3 ]] || exit 1
  sleep 15
done
[[ -c /dev/kvm ]]
export PATH="/usr/local/bin:${PATH}"

# Fail on reuse. Do not overwrite an earlier deployment or format host disks.
mkdir dev-scripts
tar -xzf dev-scripts.tar.gz -C dev-scripts
rm dev-scripts.tar.gz
cp pull-secret dev-scripts/pull_secret.json
# QEMU must reach the ISO under this source tree, as it does for TNF under /root.
# Allow directory traversal while keeping the input credentials at mode 0600.
chmod o+x "$(dirname "${PWD}")" "${PWD}"
chmod 755 dev-scripts
ln -s dev-scripts/ocp/transition install
mkdir -p /var/lib/libvirt/images/topology-transition
chmod 755 /var/lib/libvirt/images/topology-transition
jq -n --arg release "${release_image}" \
  '{network:"transitionbm", bridge:"transitionbm", gateway:"192.168.126.1", cidr:"192.168.126.0/24",
    clusterDomain:"transition.example.test", releaseImage:$release, iso:"rhcos-live.iso",
    dnsConfig:"/etc/NetworkManager/dnsmasq.d/openshift-transition.conf",
    imageDirectory:"/var/lib/libvirt/images/topology-transition"}' > state.json

# Use the same source-image and make-target handoff as TNF. Dev-scripts owns the
# initial VM, static Agent config, firmware, disk boot order, and installer waits.
cat > dev-scripts/config_root.sh <<'CONFIG'
export OPENSHIFT_CI=true
export CLUSTER_NAME=transition
export BASE_DOMAIN=example.test
export BAREMETAL_NETWORK_NAME=transitionbm
export EXTERNAL_SUBNET_V4=192.168.126.0/24
export AGENT_E2E_TEST_SCENARIO=SNO_IPV4
export AGENT_E2E_TEST_BOOT_MODE=ISO
export AGENT_PLATFORM_TYPE=none
export FEATURE_SET=CustomNoUpgrade
export FEATURE_GATES=MutableTopology=true
export MASTER_MEMORY=32768
export MASTER_VCPU=8
export MASTER_DISK=120
export NUM_EXTRA_WORKERS=0
export MIRROR_IMAGES=false
export WORKING_DIR=/opt/dev-scripts
export OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true
CONFIG
printf 'export OPENSHIFT_RELEASE_IMAGE=%q\nexport OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=%q\n' \
  "${release_image}" "${release_image}" >> dev-scripts/config_root.sh
printf 'export PULL_SECRET_FILE=%q\nexport SSH_PUB_KEY=%q\n' \
  "${PWD}/pull-secret" "$(cat ssh-publickey)" >> dev-scripts/config_root.sh
# Cache the EC2 resolver before dev-scripts switches to NetworkManager dnsmasq.
upstream_dns=$(awk '/^nameserver / && $2 !~ /:/ {print $2; exit}' /etc/resolv.conf)
[[ -n "${upstream_dns}" ]]
printf 'export ADDN_DNS=%q\n' "${upstream_dns}" >> dev-scripts/config_root.sh

# Dev-scripts uses xtrace internally. Keep its full output private on the host;
# gather publishes only known public files and the redacted installer log.
echo 'Starting dev-scripts Agent SNO install'
if (umask 022; cd dev-scripts && timeout --kill-after=5m 150m make agent) > dev-scripts.log 2>&1; then
  echo 'Dev-scripts Agent SNO install completed'
else
  result=$?
  # Report only a known phase name and exit code, never raw xtrace output.
  phase=make
  for candidate in 01_agent_requirements 01_install_requirements 02_configure_host \
    03_agent_build_installer 03_build_installer 04_agent_prepare_release \
    05_agent_configure 06_agent_create_cluster; do
    if compgen -G "dev-scripts/logs/${candidate}-*.log" >/dev/null; then
      phase=${candidate}
    fi
  done
  mkdir -p results/host
  printf 'phase=%s\nexit=%s\n' "${phase}" "${result}" > results/host/dev-scripts-status.txt
  printf 'Dev-scripts failed in %s (exit %s); gathering installer and VM logs\n' "${phase}" "${result}" >&2
  exit "${result}"
fi

# Use the payload client extracted by dev-scripts in all later steps.
cp /usr/local/bin/oc bin/oc
ln -s "${PWD}/install/openshift-install" bin/openshift-install
# shellcheck source=/dev/null
source common.sh
oc get nodes -o json > initial-nodes.json
virsh dumpxml transition_master_0 > initial-vm.xml
python3 - <<'PY'
import ipaddress
import json
from pathlib import Path
import xml.etree.ElementTree as ET

state = json.loads(Path('state.json').read_text())
nodes = json.loads(Path('initial-nodes.json').read_text())['items']
if len(nodes) != 1:
    raise SystemExit('Expected exactly one installed SNO node')

node = nodes[0]
ip = next(address['address'] for address in node['status']['addresses']
          if address['type'] == 'InternalIP' and ipaddress.ip_address(address['address']).version == 4)
if ipaddress.ip_address(ip) not in ipaddress.ip_network(state['cidr']):
    raise SystemExit('SNO address is outside the VM subnet')

vm = ET.parse('initial-vm.xml').getroot()
mac = next(interface.find('mac').get('address') for interface in vm.findall('./devices/interface')
           if any(source.get(key) == state['network'] for source in interface.findall('source')
                  for key in ('bridge', 'network')))
inventory = [dict(name=node['metadata']['name'], ip=ip, mac=mac, role='control-plane')]
Path('inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
PY

# The later node-add flow uses host HAProxy for API, MCS, and ingress.
# Keep API DNS on the SNO until both new nodes have joined.
setsebool -P haproxy_connect_any on
for port in 6443 22623; do
  semanage port -a -t http_port_t -p tcp "${port}" 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp "${port}"
done
for port in 6443 22623 80 443; do
  firewall-cmd --zone=libvirt --add-port="${port}/tcp"
done
refresh_load_balancer
set_api_dns "$(jq -er '.[0].ip' inventory.json)"

# Use a matching payload ISO for nodes added after the initial SNO install.
os_image=$(oc adm release info --registry-config=pull-secret --image-for=machine-os-images "${release_image}")
oc image extract --registry-config=pull-secret "${os_image}" --path=/coreos/coreos-x86_64.iso:. --confirm
mv coreos-x86_64.iso rhcos-live.iso
oc wait node --all --for=condition=Ready --timeout=10m
oc get clusteroperators -o json | jq -e 'all(.items[];
  any(.status.conditions[]; .type == "Available" and .status == "True") and
  all(.status.conditions[]; (.type != "Degraded" and .type != "Progressing") or .status == "False"))' >/dev/null
oc get featuregate cluster -o json | jq -e '.spec.featureSet == "CustomNoUpgrade" and
  any(.status.featureGates[]; any(.enabled[]; .name == "MutableTopology"))' >/dev/null
REMOTE

# These files contain credentials. Keep them in SHARED_DIR, never ARTIFACT_DIR.
scp "${SSHOPTS[@]}" "${remote}:${workdir}/install/auth/kubeconfig" "${SHARED_DIR}/kubeconfig"
scp "${SSHOPTS[@]}" "${remote}:${workdir}/state.json" "${SHARED_DIR}/topology-state.json"
scp "${SSHOPTS[@]}" "${remote}:${workdir}/inventory.json" "${SHARED_DIR}/topology-inventory.json"
