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

echo "### Gathering logs..."
# shellcheck disable=SC2087
timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${IP}" DISCONNECTED="${DISCONNECTED:-}" bash - << "EOF"
# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

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
