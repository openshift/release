#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator gather command ************"


if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo '#### Gathering Sos reports from all Nodes'

timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOFTOP"
    if [ $(virsh list --name |  tr -s '\n'  | wc -l) > 0 ]
    then
      export SOS_BASEDIR="/tmp/artifacts/sos"
      export HOSTFILE="${SOS_BASEDIR}/virtual_hosts.json"
      mkdir -p "${SOS_BASEDIR}"
    
      export VIRT_NET=$(virsh net-list --name  | grep -v default | tr -d "\n")
      export TMP_HOSTFILE="/tmp/tmp_hostfile.json"

      echo "[]" > ${TMP_HOSTFILE}
      virsh net-dhcp-leases --network "${VIRT_NET}" | grep 'master\|worker' | awk '{ printf("%s/%s\n", $6, $5) }' | while read -r line
      do
          _HOST=$( echo "$line" | cut -d"/" -f1 )
          _IP=$( echo "$line" | cut -d"/" -f2 )
    
          jq """. += [{ \"host\" : \"${_HOST}\", \"address\" : \"${_IP}\" }]""" < ${TMP_HOSTFILE} > ${HOSTFILE}
          cat "${HOSTFILE}" > "${TMP_HOSTFILE}"
      done
    
      jq -c ".[]" ${HOSTFILE} | while read ITEM 
      do
        _HOST=$(echo ${ITEM} | jq -r .host )
        _IP=$(echo ${ITEM} | jq -r .address )

        export REPORT_PATH="${SOS_BASEDIR}/${_HOST}"
        mkdir -p ${REPORT_PATH}; chmod o+w ${REPORT_PATH} 

        timeout -s 9 30m ssh -o StrictHostKeyChecking=off -l core $_IP REPORT_PATH="${SOS_BASEDIR}/${_HOST}" bash - << "EOF"
          mkdir -p ${REPORT_PATH} 
    
          yes | toolbox "sos report --batch --tmp-dir ${REPORT_PATH} -k crio.all=on -k crio.logs=on -k openshift.host=on -k openshift.podlogs=on \
              -o  openshift,openshift_ovn,crio,containers_common,host,containerd,logs"

           sudo chmod -R +r "${REPORT_PATH}"
EOF
        scp -o StrictHostKeyChecking=off -r "core@${_IP}:${REPORT_PATH}/*"  "${REPORT_PATH}"
      done
    fi
EOFTOP

scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"

echo "### Gathering logs..."
# shellcheck disable=SC2087
timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${IP}" DISCONNECTED="${DISCONNECTED:-}" bash - << "EOF"
# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

# Get sosreport including sar data
sos report --batch --tmp-dir /tmp/artifacts --all-logs \
  -o memory,container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,dnf,cloud_init \
  -k podman.all -k podman.logs

cp -v -r /var/log/swtpm/libvirt/qemu /tmp/artifacts/libvirt-qemu || true
ls -ltr /var/lib/swtpm-localca/ >> /tmp/artifacts/libvirt-qemu/ls-swtpm-localca.txt || true

cp -R ./reports /tmp/artifacts || true

REPO_DIR="/home/assisted-service"
if [ ! -d "${REPO_DIR}" ]; then
  mkdir -p "${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "${REPO_DIR}"
fi

cd "${REPO_DIR}"

# Get assisted logs
export LOGS_DEST=/tmp/artifacts
deploy/operator/gather.sh

EOF
