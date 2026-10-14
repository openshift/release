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

# --- Step 1: Download the PXE boot artifacts of the InfraEnv ---
INFRAENV_JSON="$(oc get infraenv "${HC_NAME}" -n "${hcp_ns}" -o json)"
KERNEL_URL="$(jq -r '.status.bootArtifacts.kernel // empty' <<< "${INFRAENV_JSON}")"
INITRD_URL="$(jq -r '.status.bootArtifacts.initrd // empty' <<< "${INFRAENV_JSON}")"
ROOTFS_URL="$(jq -r '.status.bootArtifacts.rootfs // empty' <<< "${INFRAENV_JSON}")"
if [[ -z "${KERNEL_URL}" || -z "${INITRD_URL}" || -z "${ROOTFS_URL}" ]]; then
  echo "InfraEnv ${HC_NAME} in ${hcp_ns} has incomplete bootArtifacts (kernel/initrd/rootfs)" >&2
  exit 1
fi

echo "$(date) Downloading the kernel, initrd and rootfs"
curl -k -L --fail --output /tmp/agent-kernel "${KERNEL_URL}"
curl -k -L --fail --output /tmp/agent-initrd "${INITRD_URL}"
curl -k -L --fail --output /tmp/agent-rootfs.img "${ROOTFS_URL}"

# --- Step 2: Upload the artifacts to the libvirt host ---
# Names contain ${LEASED_RESOURCE} so upi-libvirt-cleanup-post removes them.
KERNEL_NAME="${LEASED_RESOURCE}-hcpagent-kernel"
INITRD_NAME="${LEASED_RESOURCE}-hcpagent-initrd"
ROOTFS_NAME="${LEASED_RESOURCE}-hcpagent-rootfs"

# upload_volume <pool> <volume name> <local file>
function upload_volume () {
  ${VIRSH} vol-delete "$2" --pool "$1" || true
  ${VIRSH} vol-create-as \
    --name "$2" \
    --pool "$1" \
    --format raw \
    --capacity "$(wc -c < "$3")"
  ${VIRSH} -k 60 -K 5 vol-upload --vol "$2" --pool "$1" --file "$3"
}

upload_volume "${POOL_NAME}" "${KERNEL_NAME}" /tmp/agent-kernel
upload_volume "${POOL_NAME}" "${INITRD_NAME}" /tmp/agent-initrd

# The rootfs is staged in the httpd pool and fetched over plain HTTP by the
# guests, since the assisted image service route uses a cluster-internal certificate.
# The volume is created from XML so that its mode is world readable.
cat > /tmp/rootfs.xml <<EOF
<volume>
  <name>${ROOTFS_NAME}</name>
  <capacity unit="bytes">$(wc -c < /tmp/agent-rootfs.img)</capacity>
  <target>
    <path>${ROOTFS_NAME}</path>
    <permissions>
      <mode>0644</mode>
      <owner>0</owner>
      <group>0</group>
      <label>system_u:object_r:virt_image_t:s0</label>
    </permissions>
  </target>
</volume>
EOF
${VIRSH} vol-delete "${ROOTFS_NAME}" --pool "${HTTPD_POOL_NAME}" || true
${VIRSH} vol-create --file /tmp/rootfs.xml --pool "${HTTPD_POOL_NAME}"
${VIRSH} -k 60 -K 5 vol-upload --vol "${ROOTFS_NAME}" --pool "${HTTPD_POOL_NAME}" --file /tmp/agent-rootfs.img

if [[ -z "${HTTPD_PORT}" ]]; then
  HTTPD_PORT="$(leaseLookup 'httpd-port')"
fi
ROOTFS_URL_HTTPD="http://${HOSTNAME}:${HTTPD_PORT}/${ROOTFS_NAME}"
echo "$(date) Uploaded the boot artifacts, rootfs is served at ${ROOTFS_URL_HTTPD}"

KERNEL_PATH="$(${VIRSH} vol-path --pool "${POOL_NAME}" "${KERNEL_NAME}")"
INITRD_PATH="$(${VIRSH} vol-path --pool "${POOL_NAME}" "${INITRD_NAME}")"
CMDLINE="rd.neednet=1 ip=dhcp coreos.live.rootfs_url=${ROOTFS_URL_HTTPD} random.trust_cpu=on ignition.firstboot ignition.platform.id=metal console=ttysclp0"

# Writes an s390x KVM domain XML.
# $1 = domain name, $2 = mac address, $3 = output file, $4 = "install" or "disk"
# "install" boots the kernel and initrd directly and powers off on reboot, so the
# guest can be started again from the "disk" definition once the installation wrote RHCOS.
function write_domain_xml () {
  local name=$1 mac=$2 xml=$3 mode=$4
  local os_boot on_reboot
  if [[ "${mode}" == "install" ]]; then
    os_boot="<kernel>${KERNEL_PATH}</kernel>
    <initrd>${INITRD_PATH}</initrd>
    <cmdline>${CMDLINE}</cmdline>"
    on_reboot="destroy"
  else
    os_boot="<boot dev='hd'/>"
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
    ${os_boot}
  </os>
  <cpu mode='host-model'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>${on_reboot}</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source pool='${POOL_NAME}' volume='${name}-volume'/>
      <target dev='vda' bus='virtio'/>
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

# --- Step 3: Create and boot the KVM guests ---
declare -a GUEST_NAMES=()
declare -a GUEST_MACS=()
declare -a GUEST_IPS=()

for (( i=0; i<AGENT_NODE_COUNT; i++ )); do
  NAME="${LEASED_RESOURCE}-hcpagent-${i}"
  # The MAC and IP are the ones reserved for compute[i] in the lease config. The
  # libvirt network has a fixed DHCP entry for that MAC, so the guest always gets
  # the same IP. leaseLookup fails when the lease has no compute[i] entry.
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
  write_domain_xml "${NAME}" "${MAC}" "/tmp/${NAME}.xml" disk
  ${VIRSH} destroy "${NAME}" >/dev/null 2>&1 || true
  ${VIRSH} undefine "${NAME}" >/dev/null 2>&1 || true
  ${VIRSH} define "/tmp/${NAME}-install.xml"
  ${VIRSH} start "${NAME}"
  # Redefine the domain so that the next start boots from disk. The running
  # guest is not affected, and it powers off on its first reboot.
  ${VIRSH} define "/tmp/${NAME}.xml"
done
printf '%s\n' "${GUEST_NAMES[@]}" > "${SHARED_DIR}/hcpagent-kvm-guests.txt"
printf '%s\n' "${GUEST_IPS[@]}" > "${SHARED_DIR}/hcpagent-kvm-guest-ips.txt"
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
# After RHCOS is written to disk the guest powers off on reboot (install
# definition). Start it again, now from the disk definition.
for (( attempt=1; attempt<=90; attempt++ )); do
  ADDED=0
  for (( i=0; i<AGENT_NODE_COUNT; i++ )); do
    STATE="$(oc get agent "${AGENT_NAMES[i]}" -n "${hcp_ns}" -o jsonpath='{.status.debugInfo.state}')"
    echo "$(date) ${GUEST_NAMES[i]} (${AGENT_NAMES[i]}): ${STATE}"
    if [[ "${STATE}" == "added-to-existing-cluster" ]]; then
      ADDED=$((ADDED + 1))
    fi
    if [[ "$(${VIRSH} domstate "${GUEST_NAMES[i]}")" == "shut off" ]]; then
      echo "$(date) ${GUEST_NAMES[i]} is shut off after the installation, starting it from disk"
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
