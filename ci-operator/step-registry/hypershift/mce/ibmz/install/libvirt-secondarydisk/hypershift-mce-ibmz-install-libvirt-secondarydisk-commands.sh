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

# Derive the cluster name the same way upi-install-libvirt does.
if [[ "${USE_EXTERNAL_DNS:-false}" == "true" ]]; then
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi

echo "Attaching secondary libvirt disk volumes to VMs for cluster: ${CLUSTER_NAME}"
echo "  Pool: ${POOL_NAME}"
echo "  Volume capacity: ${SECONDARY_DISK_CAPACITY}"

# Collect the names of all control-plane and compute VMs that belong to this
# cluster.  Bootstrap is excluded — it is destroyed before this step runs.
declare -a vm_names=()

for (( i=0; i<=${CONTROL_COUNT}-1; i++ )); do
  vm_names+=("${CLUSTER_NAME}-control-${i}")
done

for (( i=0; i<=${COMPUTE_COUNT}-1; i++ )); do
  vm_names+=("${CLUSTER_NAME}-compute-${i}")
done

echo "VMs targeted for secondary disk attachment: ${vm_names[*]}"

for VM in "${vm_names[@]}"; do
  VOL_NAME="${VM}-lvm-disk"

  # Skip if the VM does not exist (guard against mismatched counts).
  if ! ${VIRSH} dominfo "${VM}" &>/dev/null; then
    echo "WARNING: VM ${VM} not found; skipping."
    continue
  fi

  echo "------------------------------------------------------------"
  echo "VM: ${VM}"

  # Create a new raw volume in the shared pool.
  echo "Creating volume ${VOL_NAME} (${SECONDARY_DISK_CAPACITY}) in pool ${POOL_NAME}..."
  ${VIRSH} vol-create-as \
    --pool "${POOL_NAME}" \
    --name "${VOL_NAME}" \
    --capacity "${SECONDARY_DISK_CAPACITY}" \
    --format raw

  # Determine the full volume path so we can pass it to virsh attach-disk.
  VOL_PATH=$(${VIRSH} vol-path --pool "${POOL_NAME}" "${VOL_NAME}")
  echo "Volume path: ${VOL_PATH}"

  # Attach the volume to the running VM as a persistent disk.
  # virtio bus is used for s390x KVM guests; the device name (vdc and above)
  # must not collide with vda (root) and vdb (ignition).
  echo "Attaching ${VOL_NAME} to ${VM}..."
  ${VIRSH} attach-disk "${VM}" \
    "${VOL_PATH}" \
    "${SECONDARY_DISK_DEV}" \
    --driver qemu \
    --subdriver raw \
    --targetbus virtio \
    --persistent \
    --live

  echo "Secondary disk attached successfully to ${VM}."
done

echo "============================================================"
echo "All secondary libvirt disks attached. Saving volume list..."

# Write the volume list to SHARED_DIR for potential cleanup / audit use.
printf '%s\n' "${vm_names[@]/%/-lvm-disk}" > "${SHARED_DIR}/libvirt-secondary-disk-volumes.txt"

echo "Volume list saved to \${SHARED_DIR}/libvirt-secondary-disk-volumes.txt"
echo "Secondary disk provisioning complete."
