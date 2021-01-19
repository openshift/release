#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds gather command ************"

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ]; then
  echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
  exit 1
fi

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet server IP
IP=$(cat "${SHARED_DIR}/server-ip")
SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -i "${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey")

function getlogs() {
  echo "### Downloading logs..."
  scp "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*.tar*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo "### Gathering logs..."
timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
cd dev-scripts

# Get install-gather, if there is one
cp /root/dev-scripts/ocp/ostest/log-bundle*.tar.gz /tmp/artifacts/log-bundle-\$HOSTNAME.tar.gz || true

# Get must-gather
export MUST_GATHER_PATH=/tmp/artifacts/must-gather
make gather
tar -czC "/tmp/artifacts/must-gather" -f "/tmp/artifacts/must-gather-\$HOSTNAME.tar.gz" .

# Get sosreport including sar data
sosreport --ticket-number "\$HOSTNAME" --batch -o container_log,filesys,kvm,libvirt,logs,networkmanager,podman,processor,rpm,sar,virsh,yum --tmp-dir /tmp/artifacts

# Get libvirt logs
tar -czC "/var/log/libvirt/qemu" -f "/tmp/artifacts/libvirt-logs-\$HOSTNAME.tar.gz" --transform "s?^\.?libvirt-logs-\$HOSTNAME?" .
EOF
