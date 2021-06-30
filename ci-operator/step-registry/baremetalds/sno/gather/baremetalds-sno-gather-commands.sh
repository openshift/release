#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds single-node gather command ************"

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo "### Gathering logs..."
timeout -s 9 20m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeo pipefail

# Get sosreport including sar data
sos report --batch --tmp-dir /tmp/artifacts \
  -o container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,yum \
  -k podman.all -k podman.logs

# TODO: remove when https://github.com/sosreport/sos/pull/2594 is available
cp -r /var/lib/libvirt/dnsmasq /tmp/artifacts/libvirt-dnsmasq

echo "Copy content from setup step to artifacts dir..."
cp -r /home/sno/build/ /tmp/artifacts/

export KUBECONFIG=/home/sno/build/ibip/auth/kubeconfig

echo "Waiting for cluster API to be responsive..."
timeout 5m bash -c 'until oc version; do sleep 10; done' || true

must_gather_dir=/tmp/artifacts/post-tests-must-gather
mkdir -p "${must_gather_dir}"

echo "Gathering must-gather data..."
oc adm must-gather \
  --insecure-skip-tls-verify \
  --dest-dir "${must_gather_dir}" > "${must_gather_dir}/must-gather.log"

EOF
