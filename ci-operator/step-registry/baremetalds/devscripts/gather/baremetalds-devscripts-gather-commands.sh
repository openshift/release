#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile

export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export PULL_SECRET_PATH=${cluster_profile}/pull-secret
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"

echo "************ baremetalds gather command ************"

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
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

echo "-------[ $SHARED_DIR ]"
ls -ll ${SHARED_DIR}

# Fetch packet server IP
IP=$(cat ${SHARED_DIR}/server-ip)
export IP
echo "Packet server IP is ${IP}"

if [[ ! -e ${SHARED_DIR}/server-ip ]]
then
  echo "No server IP found; skipping log gathering."
  exit 1
fi

echo "### Gathering logs..."
timeout -s 9 15m ssh $SSHOPTS root@$IP bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
export MUST_GATHER_PATH=/tmp/artifacts/must-gather
cd dev-scripts
make gather
EOF

echo "### Downloading logs..."
ssh $SSHOPTS root@$IP tar -czC "/tmp/artifacts/must-gather" -f "/tmp/artifacts/must-gather.tar.gz" .
scp $SSHOPTS root@$IP:/tmp/artifacts/must-gather.tar.gz ${ARTIFACT_DIR}
