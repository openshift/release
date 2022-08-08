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
  -o memory,container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,yum \
  -k podman.all -k podman.logs

cp -v -r /var/log/swtpm/libvirt/qemu /tmp/artifacts/libvirt-qemu || true
ls -ltr /var/lib/swtpm-localca/ >> /tmp/artifacts/libvirt-qemu/ls-swtpm-localca.txt || true

# Get information about the machine that was leased against equinix metal (e.g.: location)
EQUINIX_METADATA_TMP=$(mktemp)
curl --output "${EQUINIX_METADATA_TMP}" "https://metadata.platformequinix.com/metadata" || true
# Filter out "ssh_keys" section to prevent emails to be leaked
jq 'del(.ssh_keys)' "${EQUINIX_METADATA_TMP}" > "/tmp/artifacts/equinix-metadata.json" || true
rm "${EQUINIX_METADATA_TMP}"

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
