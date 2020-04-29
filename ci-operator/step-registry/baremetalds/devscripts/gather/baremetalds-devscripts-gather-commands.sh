#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds gather command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
${HOME}/fix_uid.sh

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

if [[ ! -e ${SHARED_DIR}/server-ip ]]
then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet server IP
IP=$(cat ${SHARED_DIR}/server-ip)

SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey"


echo "### Gathering logs..."
timeout -s 9 15m ssh $SSHOPTS root@$IP bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
export MUST_GATHER_PATH=/tmp/artifacts/must-gather
cd dev-scripts
make gather > gather.log
EOF

echo "### Downloading logs..."
ssh $SSHOPTS root@$IP tar -czC "/tmp/artifacts/must-gather" -f "/tmp/artifacts/must-gather.tar.gz" .
scp $SSHOPTS root@$IP:/tmp/artifacts/must-gather.tar.gz ${ARTIFACT_DIR}
