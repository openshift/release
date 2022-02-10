#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script should collect all the logs generated previously as well
# as collect a general state of the system under test
echo "************ baremetalds capi gather command ************"

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Copy git source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/source-code.tar.gz"

### (mko) This function is a leftover from ci-operator/step-registry/baremetalds/assisted/gather/baremetalds-assisted-gather-commands.sh
# function getlogs() {
#   echo "### Downloading logs..."

#   ssh  "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF
#   set -xeuo pipefail
#   cd /home/assisted
#   cp -v -R ./reports /tmp/artifacts || true
#   find -name '*.log' -exec cp -v {} /tmp/artifacts \; || true
# EOF

#   scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
# }

# Gather logs regardless of what happens after this
# trap getlogs EXIT

### (mko) This function is a leftover from ci-operator/step-registry/baremetalds/assisted/operator/gather/baremetalds-assisted-operator-gather-commands.sh
# function getlogs() {
#   echo "### Downloading logs..."
#   scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
# }

# # Gather logs regardless of what happens after this
# trap getlogs EXIT

echo "### Gathering logs..."
# shellcheck disable=SC2087
timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

set -xeuo pipefail
source /root/config

# Get sosreport including sar data
sos report --batch --tmp-dir /tmp/artifacts \
  -o memory,container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,yum \
  -k podman.all -k podman.logs

# TODO: remove when https://github.com/sosreport/sos/pull/2594 is available
cp -v -r /var/lib/libvirt/dnsmasq /tmp/artifacts/libvirt-dnsmasq

cp -v -r /var/log/swtpm/libvirt/qemu /tmp/artifacts/libvirt-qemu || true
ls -ltr /var/lib/swtpm-localca/ >> /tmp/artifacts/libvirt-qemu/ls-swtpm-localca.txt || true

cp -R ./reports /tmp/artifacts || true

REPO_DIR="/home/source-code"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar source code..."
  tar -xzvf /root/source-code.tar.gz -C "\${REPO_DIR}"
fi

### (mko) Below we should implement own part gathering anything that may be interesting for us.

export LOGS_DEST=/tmp/artifacts
cd "\${REPO_DIR}"
# cd "\${REPO_DIR}/deploy/"
# ./gather.sh

EOF
