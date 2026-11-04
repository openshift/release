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

# attach_secondary_disk <virsh command> <pool> <vm>
function attach_secondary_disk () {
  local virsh_cmd="$1"
  local pool="$2"
  local vm="$3"
  local vol_name="${vm}-lvm-disk"
  local vol_path

  # Skip if the VM does not exist (guard against mismatched counts).
  if ! ${virsh_cmd} dominfo "${vm}" &>/dev/null; then
    echo "WARNING: VM ${vm} not found; skipping."
    return 0
  fi

  echo "------------------------------------------------------------"
  echo "VM: ${vm}"

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
  echo "Attaching ${vol_name} to ${vm}..."
  ${virsh_cmd} attach-disk "${vm}" \
    "${vol_path}" \
    "${SECONDARY_DISK_DEV}" \
    --driver qemu \
    --subdriver raw \
    --targetbus virtio \
    --serial "${SECONDARY_DISK_SERIAL}" \
    --persistent \
    --live

  echo "Secondary disk attached successfully to ${vm}."
}

for VM in ${vm_names[@]+"${vm_names[@]}"}; do
  attach_secondary_disk "${VIRSH}" "${POOL_NAME}" "${VM}"
done

for VM in ${additional_vm_names[@]+"${additional_vm_names[@]}"}; do
  attach_secondary_disk "${VIRSH_ADDITIONAL}" "${ADDITIONAL_POOL_NAME}" "${VM}"
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
