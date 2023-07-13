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
export HOSTFILE=/tmp/artifacts/hosts.json

oc get node -o json  | jq '.items[] | { name: .metadata.name, address: .status.addresses[0].address }' | tee $HOSTFILE

jq -c '.[]' $HOSTFILE | while read item
do
  NODENAME=$(jq .name <<< $item)
  HOSTIP=$(jq .ip <<< $item)
  
  export REPORT_PATH=/host/tmp/artifacts/sos-node/$NODENAME
  mkdir -p $REPORT_PATH 

  timeout -s 9 30m ssh "${SSHOPTS[@]}" "core@$HOSTIP" DISCONNECTED="${DISCONNECTED:-}" bash - << EOF
toolbox 'sos report --batch --tmp-dir /host/$REPORT_PATH --all-logs \
  -o logs,crio,container_log,containers_common,openshift.host,openshift.podlogs,crio.logs,crio.all,boot.all-images'
EOF

done

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
