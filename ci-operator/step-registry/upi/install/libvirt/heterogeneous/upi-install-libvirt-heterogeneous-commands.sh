#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# VPN-aware heterogeneous worker bring-up for both topologies:
#   ZX: ARCH=s390x  + ADDITIONAL_WORKER_ARCHITECTURE=x86_64 (or amd64)
#   XZ: ARCH=amd64  + ADDITIONAL_WORKER_ARCHITECTURE=s390x
# Lease-driven replacement for hardcoded upi-libvirt-install-heterogeneous.

if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
if [[ ! -f "${LEASE_CONF}" ]]; then
  echo "Couldn't find lease config file at ${LEASE_CONF}"
  exit 1
fi

function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" || "${lookup}" == "null" ]]; then
    echo "Couldn't find ${1} in lease config for ${LEASED_RESOURCE}"
    exit 1
  fi
  echo "$lookup"
}

function leaseLookupOptional () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" || "${lookup}" == "null" ]]; then
    echo ""
    return
  fi
  echo "$lookup"
}

# Normalize worker arch to RHCOS stream / libvirt guest arch names.
case "${ADDITIONAL_WORKER_ARCHITECTURE}" in
  x86_64|amd64)
    WORKER_GUEST_ARCH="x86_64"
    WORKER_STREAM_ARCH="x86_64"
    ;;
  s390x)
    WORKER_GUEST_ARCH="s390x"
    WORKER_STREAM_ARCH="s390x"
    ;;
  *)
    echo "Unsupported ADDITIONAL_WORKER_ARCHITECTURE=${ADDITIONAL_WORKER_ARCHITECTURE}"
    echo "Supported: x86_64|amd64 (ZX workers) or s390x (XZ workers)"
    exit 1
    ;;
esac

# Control-plane hypervisor hosts httpd/rootfs in the current design.
HOSTNAME_CP="$(leaseLookup 'hostname')"

# Additional-arch hypervisor: prefer generic hostname-additional, then arch-specific keys.
HOSTNAME_ADDITIONAL="$(leaseLookupOptional 'hostname-additional')"
if [[ -z "${HOSTNAME_ADDITIONAL}" ]]; then
  if [[ "${WORKER_GUEST_ARCH}" == "x86_64" ]]; then
    HOSTNAME_ADDITIONAL="$(leaseLookup 'hostname-amd64')"
  else
    HOSTNAME_ADDITIONAL="$(leaseLookup 'hostname-s390x')"
  fi
fi

HTTPD_IP="$(leaseLookup 'httpd-ip')"
HTTPD_PORT="$(leaseLookupOptional 'httpd-port')"
HTTPD_PORT="${HTTPD_PORT:-8080}"

if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  BASE_DOMAIN="phc-cicd.cis.ibm.net"
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  BASE_DOMAIN="${LEASED_RESOURCE}.ci"
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi
CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
LIBVIRT_DOMAIN_NAME_SUFFIX="${LEASED_RESOURCE}"

ADDITIONAL_COUNT=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"additional-compute\" | length" "${LEASE_CONF}")
if [[ -z "${ADDITIONAL_COUNT}" || "${ADDITIONAL_COUNT}" == "null" || "${ADDITIONAL_COUNT}" -lt 1 ]]; then
  echo "Lease ${LEASED_RESOURCE} must define a non-empty additional-compute list for heterogeneous workers"
  exit 1
fi

mkdir -p /tmp/bin

if [ -n "${OPENSHIFT_CLIENT_VERSION_OVERRIDE}" ]; then
  echo "Downloading openshift client ${OPENSHIFT_CLIENT_VERSION_OVERRIDE}"
  curl -o /tmp/openshift-client-linux.tar.gz -L "https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/multi/clients/ocp/${OPENSHIFT_CLIENT_VERSION_OVERRIDE}/$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/;')/openshift-client-linux.tar.gz"
  tar -xzvf /tmp/openshift-client-linux.tar.gz -C /tmp/bin oc && chmod u+x /tmp/bin/oc
fi

export PATH=/tmp/bin:$PATH

function wait_for_domain_deletion() {
  wait_until=$(($(date +%s) + 600))

  echo "[$(date -Is)] waiting for domain $1 to be deleted, waiting until $(date -Is --date="@$wait_until")"

  until [ $((wait_until - $(date +%s)))  -le 0 ] || ! (mock-nss.sh virsh domid "$1" > /dev/null 2>&1); do
      sleep 5
  done
  if [ $((wait_until - $(date +%s))) -le 0 ]; then
    echo "Error, domain $1 was not deleted before timeout."
    return 1
  fi
  echo "Domain $1 was successfully deleted."
  return 0
}

function approve_csrs() {
  oc version --client
  while true; do
    if [[ ! -f /tmp/install-complete ]]; then
      echo "Checking for unapproved certs..."
      oc get csr | grep "Pending" || true
      oc get csr -ojson | yq-v4 -oy '.items[] | select(.status | length == 0) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
      continue
    else
      break
    fi
  done
}

VOLUME_TEMPLATE_XML=$(cat <<EOF
<volume type='file'>
  <name></name>
  <capacity unit='bytes'></capacity>
  <target>
    <path></path>
    <format type='raw'/>
    <permissions>
      <mode>0644</mode>
      <owner>0</owner>
      <group>0</group>
    </permissions>
  </target>
</volume>
EOF
)

function check_exists_in_pool {
  mock-nss.sh virsh vol-info --pool "$1" "$2" > /dev/null 2>&1
}

function upload_to_pool {
  local pool filepath filename targetPath volume_xml_path

  pool="$1"
  filepath="$2"
  filename="$(basename "$2")"
  targetPath="$3"

  if check_exists_in_pool "$pool" "$filename"; then
    echo "${filepath} already exists on pool ${pool}, skipping upload"
    return
  fi

  echo "Uploading ${filepath} to ${pool}"

  volume_xml_path=$(mktemp --tmpdir "$filename".xml.XXXXX)
  <<<"$VOLUME_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".volume.name=\"$filename\" | \
     .volume.capacity=\"$(stat -c %s "$filepath")\" | \
     .volume.target.path=\"$targetPath\"" \
    > "$volume_xml_path"

  echo "Creating volume from XML:"
  cat "$volume_xml_path"
  mock-nss.sh virsh vol-create --pool "$pool" --file "$volume_xml_path"
  mock-nss.sh virsh vol-upload --pool "$pool" --vol "$filename" --file "$filepath"
}

function delete_from_pool_if_exists {
  if check_exists_in_pool "$1" "$2"; then
    echo "Volume $2 exists in pool $1, deleting"
    mock-nss.sh virsh vol-delete --pool "$1" --vol "$2"
  fi
}

# Domain XML differs by guest architecture (x86_64 q35 vs s390-ccw-virtio).
if [[ "${WORKER_GUEST_ARCH}" == "x86_64" ]]; then
  DEFAULT_NETWORK_SOURCE="macvtap"
  DEFAULT_INTERFACE="enp1s0"
  DOMAIN_TEMPLATE_XML=$(cat <<EOF
<domain type="kvm">
  <name></name>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://redhat.com/rhel/9.2"/>
    </libosinfo:libosinfo>
  </metadata>
  <memory></memory>
  <vcpu></vcpu>
  <os>
    <type arch="x86_64" machine="q35">hvm</type>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode="host-passthrough"/>
  <clock offset="utc">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
  </clock>
  <pm>
    <suspend-to-mem enabled="no"/>
    <suspend-to-disk enabled="no"/>
  </pm>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" discard="unmap"/>
      <source file=""/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <controller type="usb" model="qemu-xhci" ports="15"/>
    <controller type="pci" model="pcie-root"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <interface type="network">
      <source network="macvtap"/>
      <mac address=""/>
      <model type="virtio"/>
    </interface>
    <console type="pty">
      <target type="serial"/>
    </console>
    <channel type="unix">
      <source mode="bind"/>
      <target type="virtio" name="org.qemu.guest_agent.0"/>
    </channel>
    <memballoon model="virtio"/>
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF
)
else
  DEFAULT_NETWORK_SOURCE="bridge"
  DEFAULT_INTERFACE="enc224"
  DOMAIN_TEMPLATE_XML=$(cat <<EOF
<domain type="kvm">
  <name></name>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://redhat.com/rhel/9.2"/>
    </libosinfo:libosinfo>
  </metadata>
  <memory></memory>
  <vcpu></vcpu>
  <os>
    <type arch="s390x" machine="s390-ccw-virtio">hvm</type>
  </os>
  <clock offset="utc"/>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" discard="unmap"/>
      <source file=""/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <interface type="network">
      <source network="bridge"/>
      <mac address=""/>
      <model type="virtio"/>
    </interface>
    <console type="pty">
      <target type="sclp"/>
    </console>
    <channel type="unix">
      <source mode="bind"/>
      <target type="virtio" name="org.qemu.guest_agent.0"/>
    </channel>
    <memballoon model="virtio"/>
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF
)
fi

HTTPD_BASE_URL="http://${HTTPD_IP}:${HTTPD_PORT}/"

echo "Preparing heterogeneous workers for cluster ${CLUSTER_DOMAIN}"
echo "  control-plane hostname (httpd/rootfs): ${HOSTNAME_CP}"
echo "  additional-arch hostname (${WORKER_GUEST_ARCH}): ${HOSTNAME_ADDITIONAL}"
echo "  ADDITIONAL_WORKER_ARCHITECTURE=${ADDITIONAL_WORKER_ARCHITECTURE} (stream=${WORKER_STREAM_ARCH})"
echo "  additional-compute count: ${ADDITIONAL_COUNT}"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

KERNEL_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${WORKER_STREAM_ARCH}.artifacts.metal.formats.pxe.kernel.location")
INITRAMFS_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${WORKER_STREAM_ARCH}.artifacts.metal.formats.pxe.initramfs.location")
ROOTFS_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${WORKER_STREAM_ARCH}.artifacts.metal.formats.pxe.rootfs.location")

echo "Found kernel=${KERNEL_URL}, initrd=${INITRAMFS_URL}, and rootfs=${ROOTFS_URL}"

KERNEL_FILENAME=$(basename "$KERNEL_URL")
INITRAMFS_FILENAME=$(basename "$INITRAMFS_URL")
ROOTFS_FILENAME=$(basename "$ROOTFS_URL")

if [[ $(dirname "$KERNEL_URL") != $(dirname "$INITRAMFS_URL") ]]; then
  echo "Error, expected kernel and initramfs to have same base url, found:"
  echo "  $(dirname "$KERNEL_URL")"
  echo "  $(dirname "$INITRAMFS_URL")"
  echo "Aborting"
  exit 1
fi

# Upload rootfs via control-plane hypervisor httpd pool.
export LIBVIRT_DEFAULT_URI="qemu+tcp://${HOSTNAME_CP}/system"
if check_exists_in_pool httpd "$ROOTFS_FILENAME"; then
  echo "rootfs ($ROOTFS_FILENAME) already exists on httpd, skipping transfer"
else
  echo "Downloading rootfs from $ROOTFS_URL"
  curl -L "$ROOTFS_URL" -o "/tmp/$ROOTFS_FILENAME"
  upload_to_pool httpd "/tmp/$ROOTFS_FILENAME" "/var/www/html/$ROOTFS_FILENAME"
fi

# Kernel/initramfs live on the additional-architecture hypervisor.
export LIBVIRT_DEFAULT_URI="qemu+tcp://${HOSTNAME_ADDITIONAL}/system"
HOST_BOOT_ARTIFACT_BASE=/var/lib/libvirt/boot/
HOST_PATH_KERNEL=${HOST_BOOT_ARTIFACT_BASE}${KERNEL_FILENAME}
HOST_PATH_INITRAMFS=${HOST_BOOT_ARTIFACT_BASE}${INITRAMFS_FILENAME}

if check_exists_in_pool boot-scratch "$KERNEL_FILENAME"; then
  echo "kernel ($KERNEL_FILENAME) already exists in boot-scratch, skipping transfer"
else
  echo "Downloading kernel from $KERNEL_URL"
  curl -o "/tmp/$KERNEL_FILENAME" -L "$KERNEL_URL"
  upload_to_pool boot-scratch "/tmp/$KERNEL_FILENAME" "$HOST_PATH_KERNEL"
fi

if check_exists_in_pool boot-scratch "$INITRAMFS_FILENAME"; then
  echo "initramfs ($INITRAMFS_FILENAME) already exists in boot-scratch, skipping transfer"
else
  echo "Downloading initramfs from $INITRAMFS_URL"
  curl -o "/tmp/$INITRAMFS_FILENAME" -L "$INITRAMFS_URL"
  upload_to_pool boot-scratch "/tmp/$INITRAMFS_FILENAME" "$HOST_PATH_INITRAMFS"
fi

for (( i=0; i<ADDITIONAL_COUNT; i++ )); do
  node_mac=$(leaseLookup "\"additional-compute\"[$i].mac")
  node_ip=$(leaseLookup "\"additional-compute\"[$i].ip")
  node_gateway=$(leaseLookup "\"additional-compute\"[$i].gateway")
  node_prefix=$(leaseLookupOptional "\"additional-compute\"[$i].prefix")
  node_prefix="${node_prefix:-255.255.255.0}"
  node_iface=$(leaseLookupOptional "\"additional-compute\"[$i].interface")
  node_iface="${node_iface:-$DEFAULT_INTERFACE}"
  node_nameserver=$(leaseLookupOptional "\"additional-compute\"[$i].nameserver")
  node_nameserver="${node_nameserver:-$HTTPD_IP}"
  node_network=$(leaseLookupOptional "\"additional-compute\"[$i].network")
  node_network="${node_network:-$DEFAULT_NETWORK_SOURCE}"

  node_name="worker-hetero-${i}-${LIBVIRT_DOMAIN_NAME_SUFFIX}"

  domain_cmdline="rd.neednet=1 coreos.inst.install_dev=/dev/vda coreos.live.rootfs_url=${HTTPD_BASE_URL}${ROOTFS_FILENAME}"
  domain_cmdline+=" ip=${node_ip}::${node_gateway}:${node_prefix}:${node_name}.${CLUSTER_DOMAIN}:${node_iface}:none:1500"
  domain_cmdline+=" nameserver=${node_nameserver}"
  domain_cmdline+=" coreos.inst.ignition_url=${HTTPD_BASE_URL}worker.ign"

  echo "Creating .qcow2 image for ${node_name}"
  delete_from_pool_if_exists default "${node_name}".qcow2
  mock-nss.sh virsh vol-create-as \
    --pool default \
    --name "${node_name}".qcow2 \
    --capacity "${DOMAIN_DISK_SIZE}" \
    --format qcow2
  domain_qcow2_image_host_path=/var/lib/libvirt/images/${node_name}.qcow2

  echo "Preparing XML for ${node_name} (${WORKER_GUEST_ARCH}, network=${node_network})"
  domain_xml_path=$(mktemp --tmpdir domain-"${node_name}".xml.XXXXX)
  <<<"$DOMAIN_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".domain.name=\"${node_name}\" |
    .domain.memory=\"${DOMAIN_MEMORY}\" |
    .domain.vcpu=\"${DOMAIN_VCPUS}\" |
    .domain.os.kernel=\"${HOST_PATH_KERNEL}\" |
    .domain.os.initrd=\"${HOST_PATH_INITRAMFS}\" |
    .domain.os.cmdline=\"${domain_cmdline}\" |
    .domain.devices.disk.source.+@file=\"${domain_qcow2_image_host_path}\" |
    .domain.devices.interface.source.+@network=\"${node_network}\" |
    .domain.devices.interface.mac.+@address=\"${node_mac}\" |
    .domain.on_reboot=\"destroy\"" \
    > "$domain_xml_path"

  echo "Creating domain"
  mock-nss.sh virsh create "$domain_xml_path" --validate

  wait_for_domain_deletion "$node_name"

  echo "Domain was deleted, creating new domain ${node_name} that boots from disk"
  domain_xml_path=$(mktemp --tmpdir domain-"${node_name}".xml.XXXXX)
  <<<"$DOMAIN_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".domain.name=\"${node_name}\" |
    .domain.memory=\"${DOMAIN_MEMORY}\" |
    .domain.vcpu=\"${DOMAIN_VCPUS}\" |
    .domain.os.boot.+@dev=\"hd\" |
    .domain.devices.disk.source.+@file=\"${domain_qcow2_image_host_path}\" |
    .domain.devices.interface.source.+@network=\"${node_network}\" |
    .domain.devices.interface.mac.+@address=\"${node_mac}\"" \
    > "$domain_xml_path"

  echo "Creating domain from XML:"
  cat "$domain_xml_path"
  mock-nss.sh virsh define "$domain_xml_path" --validate
  mock-nss.sh virsh start "$node_name"
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_HETEROGENEOUS_INSTALL_START_TIME"

echo "Approving pending CSRs"
approve_csrs &

echo "Waiting for cluster operators to become ready."
oc adm wait-for-stable-cluster

oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
oc adm wait-for-stable-cluster

oc config refresh-ca-bundle

date "+%F %X" > "${SHARED_DIR}/CLUSTER_HETEROGENEOUS_INSTALL_END_TIME"

touch /tmp/install-complete
