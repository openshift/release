#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator preinstall host command ************"

source "${SHARED_DIR}/packet-conf.sh"

echo "export INSTALLER_PULL_REF=${INSTALLER_PULL_REF}" | ssh "${SSHOPTS[@]}" "root@${IP}" "cat >> /root/env.sh"
echo "export SEED_IMAGE=${SEED_IMAGE}" | ssh "${SSHOPTS[@]}" "root@${IP}" "cat >> /root/env.sh"
echo "export SEED_IMAGE_TAG=${SEED_IMAGE_TAG}" | ssh "${SSHOPTS[@]}" "root@${IP}" "cat >> /root/env.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

source /root/env.sh

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

export IBI_BHC=$(cat ${EXTRA_BAREMETALHOSTS_FILE} | jq '.[0].driver_info.address')
export IBI_UUID=$(echo ${IBI_BHC##*/} | sed -E 's/\"//g')

REPO_DIR="/home/ib-orchestrate-vm"
if [ ! -d "${REPO_DIR}" ]; then
  mkdir -p "${REPO_DIR}"

  echo "### clone ib-orchestrate-vm..."
  git clone https://github.com/rh-ecosystem-edge/ib-orchestrate-vm.git "${REPO_DIR}"
fi

cd "${REPO_DIR}"

sudo dnf -y install runc crun gcc-c++ zip nmstate nc

mkdir tmp
podman run -v ./tmp:/tmp:Z --user root:root --rm --entrypoint='["/bin/sh","-c"]' ${INSTALLER_PULL_REF} "cp /bin/openshift-install /tmp/openshift-install"
sudo mv ./tmp/openshift-install /usr/bin/openshift-install
rm -rf tmp

set +x
export PULL_SECRET=$(cat ${PULL_SECRET_FILE} | jq -c .)
set -x

export SEED_IMAGE=${SEED_IMAGE}:${SEED_IMAGE_TAG}
podman pull ${SEED_IMAGE}
export SEED_VERSION=$(podman inspect ${SEED_IMAGE} | jq '.[0].Labels."com.openshift.lifecycle-agent.seed_cluster_info"' | jq -R -s 'split(",")' | grep seed_cluster_ocp_version | jq -R -s 'split(":")'[1] | jq -R -s 'split(",")'[0] | sed -E 's/(\\|,|\")//g')
echo ${SEED_VERSION} > seed-version
export OPENSHIFT_INSTALLER_BIN="/usr/bin/openshift-install"
export IBI_INSTALLATION_DISK="/dev/sda"
export IBI_VM_NAME=$(virsh --connect=${LIBVIRT_DEFAULT_URI} domname ${IBI_UUID})
export LIBVIRT_IMAGE_PATH=/home/libvirt-images
if [ ! -d "${LIBVIRT_IMAGE_PATH}" ]; then
  mkdir -p "${LIBVIRT_IMAGE_PATH}"
fi

make ibi-iso

tee <<EOCR > fix-boot-order.py
import libvirt
import os
import sys
from xml.etree import ElementTree
try:
    cnx = libvirt.open()
    domain = cnx.lookupByName(os.environ['IBI_VM_NAME'])
    desc = ElementTree.fromstring(domain.XMLDesc())
    os_node = desc.find('os')
    if os_node is not None:
        boot_nodes = os_node.findall('boot')
        for boot_node in boot_nodes:
            os_node.remove(boot_node)
          
    devices_node = desc.find('devices')
    if devices_node is not None:
        disk_nodes = devices_node.findall('disk')
        for index, disk_node in enumerate(disk_nodes):
            boot_index = index + 1
            disk_node.append(ElementTree.fromstring(f'<boot order="{boot_index}"/>'))
        print(len(disk_nodes))
          
    cnx.defineXML(ElementTree.tostring(desc).decode())
except libvirt.libvirtError as err:
    print(err.get_error_message())
    sys.exit(1)
EOCR

export IBI_VM_NUM_OF_DISKS=$(python fix-boot-order.py)
export IBI_ISO_BOOT_ORDER=$((IBI_VM_NUM_OF_DISKS + 1))
export IBI_TARGET_DEVICE_SUFFIX=$(echo $((97 + IBI_VM_NUM_OF_DISKS)) | awk '{ printf("%c", $0); }')

tee <<EOCR > ibi-iso.xml
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${LIBVIRT_IMAGE_PATH}/rhcos-${IBI_VM_NAME}.iso'/>
      <target dev='sd${IBI_TARGET_DEVICE_SUFFIX}' bus='sata'/>
      <boot order='${IBI_ISO_BOOT_ORDER}'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
EOCR

virsh --connect=${LIBVIRT_DEFAULT_URI} attach-device --config ${IBI_VM_NAME} ibi-iso.xml
virsh --connect=${LIBVIRT_DEFAULT_URI} destroy ${IBI_VM_NAME} || true
virsh --connect=${LIBVIRT_DEFAULT_URI} start ${IBI_VM_NAME}

sleep 60
export IBI_MACS=$(virsh --connect=${LIBVIRT_DEFAULT_URI} domiflist ${IBI_VM_NAME} | sed 1,2d | awk '{print $5}')
export IBI_VM_IP=$(for MAC in ${IBI_MACS}; do arp -n | grep -i ${MAC} | awk '{print $1}'; done | cut --delimiter " " --fields 1)
echo ${IBI_VM_IP} > ibi-vm-ip
export SSH_FLAGS="-n -o IdentityFile=/home/ib-orchestrate-vm/bip-orchestrate-vm/ssh-key/key -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
until nc -zv ${IBI_VM_IP} 22; do sleep 5; done
ssh ${SSH_FLAGS} core@${IBI_VM_IP} "sudo journalctl -flu install-rhcos-and-restore-seed.service | stdbuf -o0 -e0 awk '{print \$0 } /Finished SNO Image-based Installation./ { exit }'"

ssh ${SSH_FLAGS} core@${IBI_VM_IP} "sleep 60 && sudo shutdown now" &
sleep 70
until [[ $(virsh --connect=${LIBVIRT_DEFAULT_URI} domstate ${IBI_VM_NAME}) = "shut off" ]]; do sleep 5; done

EOF
