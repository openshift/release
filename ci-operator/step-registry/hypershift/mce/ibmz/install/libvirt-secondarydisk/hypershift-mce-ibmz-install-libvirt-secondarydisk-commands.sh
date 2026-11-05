#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

LIBVIRT_CONNECTION="qemu+tcp://${HOSTNAME}/system"
VIRSH="mock-nss.sh virsh --connect ${LIBVIRT_CONNECTION}"

# upi-install-libvirt always names domains ${LEASED_RESOURCE}-control-${i}
# and ${LEASED_RESOURCE}-compute-${i}, regardless of USE_EXTERNAL_DNS or
# UNIQUE_HASH.  CLUSTER_NAME (which appends UNIQUE_HASH) is only the
# OpenShift cluster/network name, not the libvirt domain name.
echo "Attaching secondary libvirt disk volumes to VMs for lease: ${LEASED_RESOURCE}"
echo "  Pool: ${POOL_NAME}"
echo "  Volume capacity: ${SECONDARY_DISK_CAPACITY}"

# Collect the names of all control-plane and compute VMs that belong to this
# lease on the primary (s390x) host.  Bootstrap is excluded — it is destroyed
# before this step runs.
declare -a vm_names=()

for (( i=0; i<=${CONTROL_COUNT}-1; i++ )); do
  vm_names+=("${LEASED_RESOURCE}-control-${i}")
done

for (( i=0; i<=${COMPUTE_COUNT}-1; i++ )); do
  vm_names+=("${LEASED_RESOURCE}-compute-${i}")
done

# upi-install-libvirt-heterogeneous creates the additional (amd64/arm64)
# workers on a second libvirt host, named ${LEASED_RESOURCE}-additional-compute-${idx}.
# Their count comes from the 'additional-compute' list in the lease config.
declare -a additional_vm_names=()
ADD_COMPUTE_COUNT=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"additional-compute\" | length" "${LEASE_CONF}")
for (( i=0; i<ADD_COMPUTE_COUNT; i++ )); do
  additional_vm_names+=("${LEASED_RESOURCE}-additional-compute-${i}")
done

echo "VMs targeted on primary host: ${vm_names[*]:-<none>}"
echo "VMs targeted on additional host: ${additional_vm_names[*]:-<none>}"

if [[ ${#vm_names[@]} -eq 0 && ${#additional_vm_names[@]} -eq 0 ]]; then
  echo "ERROR: No VMs targeted — CONTROL_COUNT=${CONTROL_COUNT}, COMPUTE_COUNT=${COMPUTE_COUNT} and the lease's additional-compute list all resolve to zero VMs." >&2
  exit 1
fi

if [[ ${#additional_vm_names[@]} -gt 0 ]]; then
  HOSTNAME_ADDITIONAL="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"hostname-additional\"" "${LEASE_CONF}")"
  if [[ -z "${HOSTNAME_ADDITIONAL}" || "${HOSTNAME_ADDITIONAL}" == "null" ]]; then
    echo "ERROR: Couldn't retrieve hostname-additional from lease config" >&2
    exit 1
  fi
  ADDITIONAL_LIBVIRT_URI="qemu+tcp://${HOSTNAME_ADDITIONAL}:${ADDITIONAL_LIBVIRT_PORT}/system"
  VIRSH_ADDITIONAL="mock-nss.sh virsh --connect ${ADDITIONAL_LIBVIRT_URI}"
  echo "  Additional host pool: ${ADDITIONAL_POOL_NAME}"
fi

# Power-cycle a VM so that devices added to its persistent config take effect.
# A guest reboot is not enough: it keeps the same QEMU process and old device set.
# restart_vm <virsh command> <vm>
function restart_vm () {
  local virsh_cmd="$1"
  local vm="$2"
  local state

  echo "Shutting down ${vm}..."
  ${virsh_cmd} shutdown "${vm}" || true
  for (( n=0; n<60; n++ )); do
    state=$(${virsh_cmd} domstate "${vm}" 2>/dev/null || true)
    [[ "${state}" == "shut off" ]] && break
    sleep 5
  done
  if [[ "${state}" != "shut off" ]]; then
    echo "WARNING: ${vm} did not shut down within 300s (state: ${state}); forcing power off."
    ${virsh_cmd} destroy "${vm}"
  fi

  echo "Starting ${vm}..."
  ${virsh_cmd} start "${vm}"
}

# Wait until the named OpenShift node reports Ready again after a restart.
# wait_node_ready <vm>
function wait_node_ready () {
  local vm="$1"
  local node_line

  if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
    echo "WARNING: ${SHARED_DIR}/kubeconfig not found; not waiting for node ${vm} to become Ready."
    return 0
  fi

  echo "Waiting for node ${vm} to become Ready..."
  for (( n=0; n<60; n++ )); do
    # Node names may carry a domain suffix (e.g. ".ci").
    node_line=$(KUBECONFIG="${SHARED_DIR}/kubeconfig" oc get nodes --no-headers 2>/dev/null \
      | grep -E "^${vm}(\.[a-zA-Z0-9.-]+)?[[:space:]]+" || true)
    if [[ -n "${node_line}" ]] && awk '{print $2}' <<< "${node_line}" | grep -qx "Ready"; then
      echo "Node ${vm} is Ready."
      return 0
    fi
    sleep 15
  done
  echo "ERROR: node ${vm} did not become Ready within 15 minutes." >&2
  return 1
}

# attach_secondary_disk <virsh command> <pool> <vm> [hot|cold]
#   hot  (default): hot-plug into the running VM.  Used for the s390x guests,
#        whose virtio disks sit on the CCW bus and have no PCI slots to run out of.
#   cold: add to the persistent config only, then power-cycle the VM.  Used for the
#        additional amd64/arm64 guests, which are PCIe machines.  Their domain XML
#        has no spare pcie-root-port, so hot-plug fails with "No more available PCI
#        slots"; libvirt adds the root ports it needs when the domain starts.
function attach_secondary_disk () {
  local virsh_cmd="$1"
  local pool="$2"
  local vm="$3"
  local plug_mode="${4:-hot}"
  local vol_name="${vm}-lvm-disk"
  local vol_path

  # Skip if the VM does not exist (guard against mismatched counts).
  if ! ${virsh_cmd} dominfo "${vm}" &>/dev/null; then
    echo "WARNING: VM ${vm} not found; skipping."
    return 0
  fi

  echo "------------------------------------------------------------"
  echo "VM: ${vm}"

  # The lease is exclusively ours and the VM was just recreated, so a volume with
  # this name can only be left over from an earlier run whose cleanup missed it.
  # Remove it instead of failing with "storage volume ... exists already".
  if ${virsh_cmd} vol-info --pool "${pool}" "${vol_name}" &>/dev/null; then
    echo "WARNING: stale volume ${vol_name} found in pool ${pool}; deleting it before re-creating."
    ${virsh_cmd} vol-delete --pool "${pool}" "${vol_name}"
  fi

  # Create a new raw volume in the shared pool.
  echo "Creating volume ${vol_name} (${SECONDARY_DISK_CAPACITY}) in pool ${pool}..."
  ${virsh_cmd} vol-create-as \
    --pool "${pool}" \
    --name "${vol_name}" \
    --capacity "${SECONDARY_DISK_CAPACITY}" \
    --format raw

  # Determine the full volume path so we can pass it to virsh attach-disk.
  vol_path=$(${virsh_cmd} vol-path --pool "${pool}" "${vol_name}")
  echo "Volume path: ${vol_path}"

  # Attach the volume to the running VM as a persistent disk.
  # virtio bus is used for the guests; the target device name (vdc and above)
  # must not collide with existing devices.  The serial gives the disk a stable
  # /dev/disk/by-id/virtio-<serial> path inside the guest, because the guest
  # kernel names virtio disks in discovery order, not by the target name here.
  echo "Attaching ${vol_name} to ${vm} (${plug_mode}-plug)..."
  if [[ "${plug_mode}" == "cold" ]]; then
    # --config (not --persistent): on a running domain --persistent also hot-plugs.
    ${virsh_cmd} attach-disk "${vm}" \
      "${vol_path}" \
      "${SECONDARY_DISK_DEV}" \
      --driver qemu \
      --subdriver raw \
      --targetbus virtio \
      --serial "${SECONDARY_DISK_SERIAL}" \
      --config
    restart_vm "${virsh_cmd}" "${vm}"
    wait_node_ready "${vm}"
  else
    ${virsh_cmd} attach-disk "${vm}" \
      "${vol_path}" \
      "${SECONDARY_DISK_DEV}" \
      --driver qemu \
      --subdriver raw \
      --targetbus virtio \
      --serial "${SECONDARY_DISK_SERIAL}" \
      --persistent \
      --live
  fi

  echo "Secondary disk attached successfully to ${vm}."
}

for VM in ${vm_names[@]+"${vm_names[@]}"}; do
  attach_secondary_disk "${VIRSH}" "${POOL_NAME}" "${VM}"
done

for VM in ${additional_vm_names[@]+"${additional_vm_names[@]}"}; do
  attach_secondary_disk "${VIRSH_ADDITIONAL}" "${ADDITIONAL_POOL_NAME}" "${VM}" cold
done

echo "============================================================"
echo "All secondary libvirt disks attached. Saving volume list..."

# Write the volume list to SHARED_DIR for potential cleanup / audit use.
all_vm_names=(${vm_names[@]+"${vm_names[@]}"} ${additional_vm_names[@]+"${additional_vm_names[@]}"})
printf '%s\n' "${all_vm_names[@]/%/-lvm-disk}" > "${SHARED_DIR}/libvirt-secondary-disk-volumes.txt"
echo "Volume list saved to \${SHARED_DIR}/libvirt-secondary-disk-volumes.txt"

# Tell the LVM step which block device to use as the physical volume.
# hypershift-mce-agent-lvm-commands.sh reads ${SHARED_DIR}/lvmdevice and
# falls back to /dev/vda when the file is absent — which would make LVM
# consume the root disk instead of the secondary disk attached above.
# The by-id path is identical on s390x and amd64 nodes, unlike /dev/vdX.
LVM_DEVICE="/dev/disk/by-id/virtio-${SECONDARY_DISK_SERIAL}"
echo "${LVM_DEVICE}" > "${SHARED_DIR}/lvmdevice"
echo "LVM device path written to \${SHARED_DIR}/lvmdevice: ${LVM_DEVICE}"

echo "Secondary disk provisioning complete."
