#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator gather command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

export HUB_DIR=/ibio-gather/hub
mkdir -p ${HUB_DIR}
oc get baremetalhost ostest-extraworker-0 -n openshift-machine-api -o yaml > ${HUB_DIR}/baremetalhost.yaml
oc get dataimage ostest-extraworker-0 -n openshift-machine-api -o yaml > ${HUB_DIR}/dataimage.yaml
oc get clusterdeployment ibi-cluster -n ibi-cluster -o yaml > ${HUB_DIR}/clusterdeployment.yaml
oc get imageclusterinstall ibi-cluster -n ibi-cluster -o yaml > ${HUB_DIR}/imageclusterinstall.yaml
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c manager > ${HUB_DIR}/image-based-install-operator-manager.log
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c server > ${HUB_DIR}/image-based-install-operator-server.log

export IBI_HOST_DIR=/ibio-gather/ibi-host
mkdir -p ${IBI_HOST_DIR}
export IBI_VM_IP=$(cat /home/ib-orchestrate-vm/ibi-vm-ip)
export SSH_FLAGS="-n -o IdentityFile=/home/ib-orchestrate-vm/bip-orchestrate-vm/ssh-key/key -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
# even if there is an error connecting to the ibi-host we still want the previous artifacts, so don't fail
ssh ${SSH_FLAGS} core@${IBI_VM_IP} "sudo journalctl -u installation-configuration.service" > ${IBI_HOST_DIR}/installation-configuration.log || true
ssh ${SSH_FLAGS} core@${IBI_VM_IP} "sudo tar -czf - /opt/openshift" > ${IBI_HOST_DIR}/opt-openshift.tar.gz || true
ssh ${SSH_FLAGS} core@${IBI_VM_IP} "sudo mkdir /mnt/config-iso && sudo mount /dev/sr0 /mnt/config-iso && sudo tar -czf - /mnt/config-iso" > ${IBI_HOST_DIR}/config-iso.tar.gz || true

EOF

ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /ibio-gather | tar -C "${ARTIFACT_DIR}" -xzf -
