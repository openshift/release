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
scp "${SSHOPTS[@]}" "$(command -v oc)" "${remote}:${workdir}/bin/oc"
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${remote}:${workdir}/ssh-publickey"
scp "${SSHOPTS[@]}" /var/run/rhsm/subscription-manager-{org,act-key} "${remote}:${workdir}/"

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
ssh "${SSHOPTS[@]}" "${remote}" sudo bash -s -- "${workdir}" "${RELEASE_IMAGE_LATEST}" <<'REMOTE'
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
for attempt in 1 2 3; do
  if dnf install -y qemu-kvm libvirt virt-install edk2-ovmf jq podman haproxy \
    policycoreutils-python-utils openssl nmstate; then
    break
  fi
  [[ ${attempt} -lt 3 ]] || exit 1
  sleep 15
done
[[ -c /dev/kvm ]]
systemctl enable --now libvirtd
setsebool -P haproxy_connect_any on
# Permit API and MCS listeners, as in TNT's HAProxy setup on enforcing hosts.
for port in 6443 22623; do
  semanage port -a -t http_port_t -p tcp "${port}" 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp "${port}"
done
mkdir -p /var/lib/libvirt/images/topology-transition
chmod 755 /var/lib/libvirt/images/topology-transition

oc adm release extract --registry-config=pull-secret --command=openshift-install --to=bin "${release_image}"
# Do not truncate the oc binary that is running this extraction.
mkdir -p extracted-cli
oc adm release extract --registry-config=pull-secret --command=oc --to=extracted-cli "${release_image}"
mv extracted-cli/oc bin/oc
rmdir extracted-cli
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${release_image}"
cluster_domain=transition.example.test
jq -n --arg domain "${cluster_domain}" --arg release "${release_image}" \
  '{network:"topology-transition", bridge:"virbr-tt", gateway:"192.168.126.1", cidr:"192.168.126.0/24",
    clusterDomain:$domain, releaseImage:$release, iso:"rhcos-live.iso", imageDirectory:"/var/lib/libvirt/images/topology-transition"}' > state.json
printf '[{"name":"master-0","mac":"52:54:00:7a:00:0a","ip":"192.168.126.10","role":"control-plane"}]\n' > inventory.json

# Keep the original upstream resolver. Using resolv.conf here would create a DNS loop.
upstream_dns=$(awk '/^nameserver / && $2 !~ /:/ {print $2; exit}' /etc/resolv.conf)
[[ -n "${upstream_dns}" ]]
cat > network.xml <<EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>topology-transition</name>
  <forward mode='nat'/>
  <bridge name='virbr-tt' stp='on' delay='0'/>
  <domain name='${cluster_domain}' localOnly='yes'/>
  <dns>
    <forwarder addr='${upstream_dns}'/>
    <host ip='192.168.126.10'><hostname>master-0</hostname><hostname>master-0.${cluster_domain}</hostname><hostname>api.${cluster_domain}</hostname><hostname>api-int.${cluster_domain}</hostname></host>
  </dns>
  <ip address='192.168.126.1' netmask='255.255.255.0'><dhcp><range start='192.168.126.2' end='192.168.126.9'/></dhcp></ip>
  <dnsmasq:options><dnsmasq:option value='address=/.apps.${cluster_domain}/192.168.126.1'/></dnsmasq:options>
</network>
EOF
virsh net-define network.xml
virsh net-start topology-transition
virsh net-autostart topology-transition
printf 'nameserver 192.168.126.1\n' > /etc/resolv.conf
if systemctl is-active --quiet firewalld; then
  for port in 6443 22623 80 443; do
    firewall-cmd --zone=libvirt --add-port="${port}/tcp"
  done
fi

mkdir -p install
cat > install/install-config.yaml <<EOF
apiVersion: v1
baseDomain: example.test
metadata:
  name: transition
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 1
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 192.168.126.0/24
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
featureSet: CustomNoUpgrade
featureGates:
- MutableTopology=true
pullSecret: '$(jq -c . pull-secret)'
sshKey: '$(cat ssh-publickey)'
EOF
cp install/install-config.yaml install/install-config.saved.yaml
cat > install/agent-config.yaml <<EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: transition
rendezvousIP: 192.168.126.10
additionalNTPSources:
- 0.rhel.pool.ntp.org
- 1.rhel.pool.ntp.org
- 2.rhel.pool.ntp.org
hosts:
- hostname: master-0
  role: master
  rootDeviceHints:
    deviceName: /dev/vda
  interfaces:
  - name: eth0
    macAddress: 52:54:00:7a:00:0a
  networkConfig:
    interfaces:
    - name: eth0
      type: ethernet
      state: up
      mac-address: 52:54:00:7a:00:0a
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: 192.168.126.10
          prefix-length: 24
      ipv6:
        enabled: false
    dns-resolver:
      config:
        server:
        - 192.168.126.1
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: 192.168.126.1
        next-hop-interface: eth0
        table-id: 254
EOF
openshift-install --dir=install agent create image

# Both the installer and the ISO come from this job's payload.
os_image=$(oc adm release info --registry-config=pull-secret --image-for=machine-os-images "${release_image}")
oc image extract --registry-config=pull-secret "${os_image}" --path=/coreos/coreos-x86_64.iso:. --confirm
mv coreos-x86_64.iso rhcos-live.iso
# shellcheck source=/dev/null
source common.sh
refresh_load_balancer

# Like sno-agent, start a persistent UEFI VM with disk-first boot order.
# Agent manages the installation and reboots without virt-install's install phase.
if virsh dominfo master-0 >/dev/null 2>&1 || [[ -e "${image_dir}/master-0.qcow2" || -e "${image_dir}/master-0.iso" ]]; then
  echo 'VM name or disk overlaps an existing resource' >&2
  exit 1
fi
virsh net-update "${network}" add-last ip-dhcp-host \
  "<host mac='52:54:00:7a:00:0a' name='master-0' ip='192.168.126.10'/>" --live --config
qemu-img create -f qcow2 "${image_dir}/master-0.qcow2" 120G
cp install/agent.x86_64.iso "${image_dir}/master-0.iso"
chmod 644 "${image_dir}/master-0.iso"
restorecon -R "${image_dir}"
virt-install --connect qemu:///system --name master-0 --memory 32768 --vcpus 8 \
  --cpu host-passthrough --disk "${image_dir}/master-0.qcow2,bus=virtio" \
  --network "network=${network},model=virtio,mac=52:54:00:7a:00:0a" \
  --disk "${image_dir}/master-0.iso,device=cdrom" --os-variant rhel9.0 --graphics none \
  --import --noautoconsole --boot hd,cdrom --events on_reboot=restart \
  --boot loader=/usr/share/edk2/ovmf/OVMF_CODE.fd,loader_ro=yes,loader_type=pflash,nvram_template=/usr/share/edk2/ovmf/OVMF_VARS.fd,loader_secure=no \
  --tpm none --serial "file,path=/var/log/libvirt/qemu/master-0-console.log"

openshift-install --dir=install agent wait-for bootstrap-complete --log-level=info 2>&1 |
  sed -E 's/(password: (\\?")?)[^"\\[:space:]]+/\1REDACTED/g'
openshift-install --dir=install agent wait-for install-complete --log-level=info 2>&1 |
  sed -E 's/(password: (\\?")?)[^"\\[:space:]]+/\1REDACTED/g'
oc wait node --all --for=condition=Ready --timeout=10m
oc get nodes -o json | jq -e '.items | length == 1' >/dev/null
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
scp "${SSHOPTS[@]}" -r "${remote}:${workdir}/install" "${SHARED_DIR}/topology-install"
