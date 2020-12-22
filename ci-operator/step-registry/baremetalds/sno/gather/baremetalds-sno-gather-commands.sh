#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds sno gather command ************"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

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
  scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo "### Gathering logs..."
timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

# Get sosreport including sar data
sosreport --ticket-number "\$HOSTNAME" --batch -o container_log,filesys,kvm,libvirt,logs,networkmanager,podman,processor,rpm,sar,virsh,yum --tmp-dir /tmp/artifacts

cp -r /home/sno/build/ /tmp/artifacts/

EOF
