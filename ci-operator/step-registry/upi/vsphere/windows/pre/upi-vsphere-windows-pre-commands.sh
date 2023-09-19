#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# createWindowsInstanceFile creates the a text file in the shared dir with the
# following naming convention:
#   <address>_windows_instance.txt
# where, <address> is the network address used to SSH into the Windows instance.
# See https://github.com/openshift/windows-machine-config-operator#adding-instances
function createWindowsInstanceFile() {
  ADDRESS=$1
  USERNAME=$2
  # set file name
  windows_instance_file="${SHARED_DIR}/${ADDRESS}_windows_instance.txt"
  # create file with instance information
  echo "username=${USERNAME}" >"${windows_instance_file}"
  echo "$(date -u --rfc-3339=seconds) - created ${windows_instance_file}"
}

# Creates a folder at the given path if it does not exist.
# Will return error if the parent folder also does not exist.
# Takes the folder's path as an argument.
function ensureVMFolderExists() {
  folder=$1
  if ! govc folder.info $folder; then
    echo "$(date -u --rfc-3339=seconds) - creating folder $folder..."
    govc folder.create $folder
    echo "${folder}" >>"${SHARED_DIR}/windows_vm_folders.txt"
  fi
}

echo "$(date -u --rfc-3339=seconds) - provisioning Windows VM on vSphere..."

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_resource_pool
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"

echo "$(date -u --rfc-3339=seconds) - configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

# get information from shared dir
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
vm_template=$(<"${SHARED_DIR}"/windows_vm_template.txt)
vm_template_username=$(<"${SHARED_DIR}"/windows_vm_template_username.txt)

# set VM folder
vm_folder="/${vsphere_datacenter}/vm/${cluster_name}"

# ensure that the VM folder exists
ensureVMFolderExists $vm_folder

# WINDOWS_VM_COUNT holds the total number of Windows VM, read from env var to
# allow configuration from the workflow definition. Otherwise, default to 1.
WINDOWS_VM_COUNT=${WINDOWS_VM_COUNT:-1}

vm_index=0
while [ $vm_index -lt $WINDOWS_VM_COUNT ]; do
  # create an unique VM name with the following pattern:
  #   <cluster_name>-win-<vm_index>
  # where, <vm_index> goes from 0 to $WINDOWS_VM_COUNT-1 and
  # <cluster_name> is the name of the cluster
  vm_name="${cluster_name}-win-${vm_index}"

  # save the VM name to shared dir, used in the deprovision step to find and
  # destroy the created VM. The filename pattern must be:
  #   <vm_name>_e2e_vsphere_vm.txt
  # where, <vm_name> is the name of the VM in vCenter
  touch "${SHARED_DIR}/${vm_name}_e2e_vsphere_vm.txt"

  # create VM
  # TODO: modularize the VM creation in a function. e.g. createVM()
  echo "$(date -u --rfc-3339=seconds) - creating VM ${vm_name} from template ${vm_template}"
  govc vm.clone \
    -on=false \
    -c 4 \
    -m 16384 \
    -net="${vsphere_portgroup}" \
    -pool "${vsphere_resource_pool}" \
    -ds "${vsphere_datastore}" \
    -folder="${vm_folder}" \
    -vm "${vm_template}" \
    "${vm_name}"

  echo "$(date -u --rfc-3339=seconds) - provisioning disk for VM ${vm_name}"
  govc vm.disk.change -vm "${vm_name}" -size=128GB
  # enable consistent UUID
  govc vm.change -vm "${vm_name}" -e disk.EnableUUID=TRUE

  echo "$(date -u --rfc-3339=seconds) - powering on VM ${vm_name}"
  govc vm.power -on=true "${vm_name}"

  # wait for VM to power-on and get an IP address
  echo "$(date -u --rfc-3339=seconds) - waiting for IP address for VM ${vm_name}"
  sleep 60
  vm_ip=$(govc vm.ip -a -v4 -wait=20m "${vm_name}")
  if [ -z $vm_ip ]; then
    echo "$(date -u --rfc-3339=seconds) - timeout waiting for IP address for VM ${vm_name}"
    exit 1
  fi
  echo "$(date -u --rfc-3339=seconds) - VM ${vm_name} provisioned with IP address ${vm_ip}"

  createWindowsInstanceFile "${vm_ip}" "${vm_template_username}" || {
    echo "$(date -u --rfc-3339=seconds) - error creating Windows instance file for ${vm_ip}"
    exit 1
  }
  # next index
  ((vm_index++)) || true
done

echo "$(date -u --rfc-3339=seconds) - provisioned $WINDOWS_VM_COUNT Windows VM(s) on vSphere"
