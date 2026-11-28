#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator post gather command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

export ARTIFACT_DIR=/ibio-post-gather
mkdir -p ${ARTIFACT_DIR}
oc get baremetalhost ostest-extraworker-0 -n openshift-machine-api -o yaml > ${ARTIFACT_DIR}/baremetalhost.yaml
# in case of an error in deleting the dataimage, we want to see it
oc get dataimage ostest-extraworker-0 -n openshift-machine-api -o yaml > ${ARTIFACT_DIR}/dataimage.yaml || true
oc get clusterdeployment ibi-cluster -n ibi-cluster -o yaml > ${ARTIFACT_DIR}/clusterdeployment.yaml
# in case of an error in deleting the imageclusterinstall, we want to see it
oc get imageclusterinstall ibi-cluster -n ibi-cluster -o yaml > ${ARTIFACT_DIR}/imageclusterinstall.yaml || true
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c manager > ${ARTIFACT_DIR}/image-based-install-operator-manager.log
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c server > ${ARTIFACT_DIR}/image-based-install-operator-server.log

# Gather logs from the IBI host itself. The image-based-install-operator-gather step only runs
# when the install step succeeds, so this is the only place that records why a host failed to
# come up. This is best effort: it must never fail the step.
export IBI_HOST_DIR=${ARTIFACT_DIR}/ibi-host
mkdir -p ${IBI_HOST_DIR}
export IBI_VM_IP_FILE=/home/ib-orchestrate-vm/ibi-vm-ip
if [[ -s ${IBI_VM_IP_FILE} ]]; then
  export IBI_VM_IP=$(cat ${IBI_VM_IP_FILE})
  # -n keeps ssh from consuming the rest of this script, which bash is reading from stdin
  export SSH_FLAGS="-n -o IdentityFile=/home/ib-orchestrate-vm/bip-orchestrate-vm/ssh-key/key -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
  function ibi_host() {
    timeout 5m ssh ${SSH_FLAGS} core@${IBI_VM_IP} "$1"
  }
  ibi_host "sudo journalctl --no-pager -b | gzip -c" > ${IBI_HOST_DIR}/journal.log.gz || true
  ibi_host "sudo journalctl --no-pager -u installation-configuration.service" > ${IBI_HOST_DIR}/installation-configuration.log || true
  ibi_host "sudo systemctl list-units --failed --no-pager" > ${IBI_HOST_DIR}/failed-units.txt || true
  ibi_host "ip addr; ip route; ip -6 route" > ${IBI_HOST_DIR}/network.txt || true
  ibi_host "sudo ss -tlnp" > ${IBI_HOST_DIR}/listening-sockets.txt || true
  ibi_host "sudo crictl ps -a" > ${IBI_HOST_DIR}/crictl-ps.txt || true
  # an unreachable host leaves empty files behind, drop them so the artifacts are not misleading
  find ${IBI_HOST_DIR} -type f -empty -delete || true
else
  echo "No IBI host IP recorded in ${IBI_VM_IP_FILE}, skipping IBI host gather"
fi

EOF

ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /ibio-post-gather | tar -C "${ARTIFACT_DIR}" -xzf -
