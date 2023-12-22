#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "$CLUSTER_NAME" << 'EOF'
CLUSTER_NAME="$1"

LOCK="/tmp/reserved_file.lock"
LOCK_FD=200
touch $LOCK
exec 200>$LOCK

set -e
trap catch_exit ERR INT

function catch_exit {
  echo "Error. Releasing lock $LOCK_FD ($LOCK)"
  flock -u $LOCK_FD
  exit 1
}

echo "Acquiring lock $LOCK_FD ($LOCK) (waiting up to 10 minutes)"
flock -w 600 $LOCK_FD
echo "Lock acquired $LOCK_FD ($LOCK)"

sed -i "/,${CLUSTER_NAME},ci-op,/d" /etc/hosts_pool_reserved
sed -i "/,${CLUSTER_NAME},ci-op,/d" /etc/vips_reserved

echo "Releasing lock $LOCK_FD ($LOCK)"
flock -u $LOCK_FD
# TODO normalize and sanitize paths
rm -rf /{var/builds,opt/html,opt/tftpboot,opt/nfs}/${CLUSTER_NAME}
# Delete agent-installer images, if any
rm -f /opt/html/${CLUSTER_NAME}.*.iso

EOF
