#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Hosted cluster identity written by hypershift-mce-ibmz-create-hcpagent-oz
HC_NAME="$(cat "${SHARED_DIR}/cluster-name")"
HC_NS="$(cat "${SHARED_DIR}/cluster-namespace")"
hcp_ns="${HC_NS}-${HC_NAME}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
echo "$(date) Hosted cluster: ${HC_NAME}, namespace: ${HC_NS}, agent namespace: ${hcp_ns}"

if ! command -v jq >/dev/null 2>&1; then
  mkdir -p /tmp/bin
  curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
  export PATH=$PATH:/tmp/bin
fi

# Resolve the libvirt hypervisor hostname from the lease config.
LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "$lookup"
}

HOSTNAME="$(leaseLookup 'hostname')"
LIBVIRT_CONNECTION="qemu+tcp://${HOSTNAME}/system"
VIRSH="mock-nss.sh virsh --connect ${LIBVIRT_CONNECTION}"

# Libvirt network the guests are attached to. Defaults to the management
# cluster network, named the same way as in upi-install-libvirt.
if [[ -n "${GUEST_NETWORK}" ]]; then
  NETWORK="${GUEST_NETWORK}"
elif [[ "${USE_EXTERNAL_DNS}" == "true" ]]; then
  NETWORK="${LEASED_RESOURCE}"
else
  NETWORK="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi
${VIRSH} net-info "${NETWORK}" >/dev/null
echo "$(date) Using libvirt network ${NETWORK} on ${HOSTNAME}"

# --- Step 1: Download the discovery ISO from the InfraEnv ---
# The ISO is self-contained (kernel + initrd + rootfs). No HTTP server needed.
INFRAENV_JSON="$(oc get infraenv "${HC_NAME}" -n "${hcp_ns}" -o json)"
ISO_URL="$(jq -r '.status.isoDownloadURL // empty' <<< "${INFRAENV_JSON}")"
if [[ -z "${ISO_URL}" ]]; then
  echo "$(date) ERROR: InfraEnv ${HC_NAME} in ${hcp_ns} has no isoDownloadURL" >&2
  exit 1
fi
echo "$(date) Downloading the discovery ISO"
curl -k -L --fail --output /tmp/agent-discovery.iso "${ISO_URL}"
echo "$(date) ISO downloaded: $(wc -c < /tmp/agent-discovery.iso) bytes"

# --- Step 2: Upload the ISO to the libvirt storage pool ---
# Named with LEASED_RESOURCE so upi-libvirt-cleanup-post removes it.
ISO_VOLUME="${LEASED_RESOURCE}-hcpagent-discovery.iso"
${VIRSH} vol-delete "${ISO_VOLUME}" --pool "${POOL_NAME}" || true
${VIRSH} vol-create-as \
  --name "${ISO_VOLUME}" \
  --pool "${POOL_NAME}" \
  --format raw \
  --capacity "$(wc -c < /tmp/agent-discovery.iso)"
${VIRSH} -k 60 -K 5 vol-upload \
  --vol "${ISO_VOLUME}" \
  --pool "${POOL_NAME}" \
  --file /tmp/agent-discovery.iso
echo "$(date) Uploaded ISO as ${POOL_NAME}/${ISO_VOLUME}"

ISO_PATH="$(${VIRSH} vol-path --pool "${POOL_NAME}" "${ISO_VOLUME}")"

# Writes an s390x KVM domain XML.
# $1 = domain name, $2 = mac address, $3 = output file, $4 = "install" or "disk"
# "install": boots cdrom first, powers off on reboot so we can redefine for disk boot.
# "disk":    boots from the qcow2 disk only, no cdrom attached.
function write_domain_xml () {
  local name=$1 mac=$2 xml=$3 mode=$4
  local cdrom_xml=""
  local boot_xml=""
  local on_reboot=""

  if [[ "${mode}" == "install" ]]; then
    cdrom_xml="<disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${ISO_PATH}'/>
      <target dev='sda' bus='scsi'/>
      <readonly/>
      <boot order='1'/>
    </disk>"
    boot_xml=""
    on_reboot="destroy"
  else
    cdrom_xml=""
    boot_xml="<boot dev='hd'/>"
    on_reboot="restart"
  fi

  cat > "${xml}" <<EOF
<domain type='kvm'>
  <name>${name}</name>
  <memory unit='MiB'>${AGENT_GUEST_MEMORY}</memory>
  <currentMemory unit='MiB'>${AGENT_GUEST_MEMORY}</currentMemory>
  <vcpu placement='static'>${AGENT_GUEST_VCPUS}</vcpu>
  <os>
    <type arch='s390x' machine='s390-ccw-virtio'>hvm</type>
    ${boot_xml}
  </os>
  <cpu mode='host-model'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>${on_reboot}</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    ${cdrom_xml}
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source pool='${POOL_NAME}' volume='${name}-volume'/>
      <target dev='vda' bus='virtio'/>
      $([[ "${mode}" == "install" ]] && echo "<boot order='2'/>" || true)
    </disk>
    <interface type='network'>
      <mac address='${mac}'/>
      <source network='${NETWORK}'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'>
      <target type='sclp' port='0'/>
    </console>
  </devices>
</domain>
EOF
}

# --- Step 3: Create and boot the KVM guests from the ISO ---
declare -a GUEST_NAMES=()
declare -a GUEST_MACS=()
declare -a GUEST_IPS=()

for (( i=0; i<AGENT_NODE_COUNT; i++ )); do
  NAME="${LEASED_RESOURCE}-hcpagent-${i}"
  # Use the lease compute MACs so DHCP assigns the fixed IPs (.51, .52, ...)
  MAC="$(leaseLookup "compute[${i}].mac" | tr '[:upper:]' '[:lower:]')"
  IP="$(leaseLookup "compute[${i}].ip")"
  GUEST_NAMES+=("${NAME}")
  GUEST_MACS+=("${MAC}")
  GUEST_IPS+=("${IP}")

  echo "$(date) Creating KVM guest ${NAME} (${MAC}, ${IP})"
  ${VIRSH} vol-delete "${NAME}-volume" --pool "${POOL_NAME}" || true
  ${VIRSH} vol-create-as \
    --name "${NAME}-volume" \
    --pool "${POOL_NAME}" \
    --format qcow2 \
    --capacity "${AGENT_GUEST_DISK_CAPACITY}"

  write_domain_xml "${NAME}" "${MAC}" "/tmp/${NAME}-install.xml" install
  # Pre-write the disk XML; it will be defined after the install powers off.
  write_domain_xml "${NAME}" "${MAC}" "/tmp/${NAME}-disk.xml" disk

  ${VIRSH} destroy "${NAME}" >/dev/null 2>&1 || true
  ${VIRSH} undefine "${NAME}" >/dev/null 2>&1 || true
  ${VIRSH} define "/tmp/${NAME}-install.xml"
  ${VIRSH} start "${NAME}"
  echo "$(date) Guest ${NAME} started, booting from ISO"
done
printf '%s\n' "${GUEST_NAMES[@]}" > "${SHARED_DIR}/hcpagent-kvm-guests.txt"
printf '%s\n' "${GUEST_IPS[@]}"   > "${SHARED_DIR}/hcpagent-kvm-guest-ips.txt"
echo "$(date) KVM guest IPs: ${GUEST_IPS[*]}"

# Prints the name of the Agent whose interface has the given MAC address.
function agent_for_mac () {
  oc get agents -n "${hcp_ns}" -o json | jq -r --arg mac "$1" \
    '[.items[] | select(any(.status.inventory.interfaces[]?; (.macAddress // "" | ascii_downcase) == $mac)) | .metadata.name] | first // empty'
}

# --- Step 4: Wait for the guests to register as Agents ---
declare -a AGENT_NAMES=()
for (( attempt=1; attempt<=60; attempt++ )); do
  FOUND=0
  for (( i=0; i<AGENT_NODE_COUNT; i++ )); do
    AGENT_NAMES[i]="$(agent_for_mac "${GUEST_MACS[i]}")"
    if [[ -n "${AGENT_NAMES[i]}" ]]; then
      FOUND=$((FOUND + 1))
    fi
  done
  if [[ "${FOUND}" -eq "${AGENT_NODE_COUNT}" ]]; then
    echo "$(date) All ${AGENT_NODE_COUNT} KVM guests registered as agents: ${AGENT_NAMES[*]}"
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    echo "$(date) ERROR: only ${FOUND}/${AGENT_NODE_COUNT} guests registered as agents after 30 minutes" >&2
    oc get agents -n "${hcp_ns}" -o wide || true
    exit 1
  fi
  echo "$(date) ${FOUND}/${AGENT_NODE_COUNT} agents registered, waiting... (${attempt}/60)"
  sleep 30
done

# --- Step 5: Approve the agents and attach them to the hosted cluster ---
for (( i=0; i<AGENT_NODE_COUNT; i++ )); do
  oc -n "${hcp_ns}" patch agent "${AGENT_NAMES[i]}" --type merge \
    -p "{\"spec\":{\"approved\":true,\"hostname\":\"${HC_NAME}-compute-${i}\"}}"
done
oc -n "${HC_NS}" scale nodepool "${HC_NAME}" --replicas "${AGENT_NODE_COUNT}"
echo "$(date) Approved the agents and scaled nodepool ${HC_NAME} to ${AGENT_NODE_COUNT}"

# --- Step 6: Wait for installation to finish ---
# After RHCOS is written to disk the guest powers off (on_reboot=destroy in
# the install definition). Undefine it, define the disk-only XML, then start.
for (( attempt=1; attempt<=90; attempt++ )); do
  ADDED=0
  for (( i=0; i<AGENT_NODE_COUNT; i++ )); do
    STATE="$(oc get agent "${AGENT_NAMES[i]}" -n "${hcp_ns}" -o jsonpath='{.status.debugInfo.state}')"
    echo "$(date) ${GUEST_NAMES[i]} (${AGENT_NAMES[i]}): ${STATE}"
    if [[ "${STATE}" == "added-to-existing-cluster" ]]; then
      ADDED=$((ADDED + 1))
    fi
    if [[ "$(${VIRSH} domstate "${GUEST_NAMES[i]}")" == "shut off" ]]; then
      echo "$(date) ${GUEST_NAMES[i]} is shut off after install, redefining from disk XML and starting"
      ${VIRSH} undefine "${GUEST_NAMES[i]}" >/dev/null 2>&1 || true
      ${VIRSH} define "/tmp/${GUEST_NAMES[i]}-disk.xml"
      ${VIRSH} start "${GUEST_NAMES[i]}"
    fi
  done
  if [[ "${ADDED}" -eq "${AGENT_NODE_COUNT}" ]]; then
    echo "$(date) All agents are attached as compute nodes to the hosted control plane"
    break
  fi
  if [[ "${attempt}" -eq 90 ]]; then
    echo "$(date) ERROR: only ${ADDED}/${AGENT_NODE_COUNT} agents were added to the cluster after 45 minutes" >&2
    oc get agents -n "${hcp_ns}" -o wide || true
    exit 1
  fi
  sleep 30
done

# --- Step 7: Verify the nodes in the hosted cluster ---
echo "$(date) Checking the compute nodes in the hosted control plane"
oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" get nodes
oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" wait --for=condition=Ready node --all --timeout=15m

# --- Step 8: Verify the guest ingress service ---
# The agent guest router runs in HostNetwork mode and listens on port 80/443
# directly on the node IP. Confirm here so HAProxy backends can be checked.
echo "$(date) Checking guest ingress service"
oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" get svc -n openshift-ingress

# --- Step 9: Wait for all guest ClusterOperators to be Available ---
# COs require compute nodes to be Ready before they can progress.
echo "$(date) Waiting for all guest ClusterOperators to be Available"
oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" \
  wait --for=condition=Available=True co --all --timeout=30m
echo "$(date) All guest ClusterOperators are Available"

echo "$(date) Successfully attached the KVM guests as agents to the hosted cluster ${HC_NAME}"
