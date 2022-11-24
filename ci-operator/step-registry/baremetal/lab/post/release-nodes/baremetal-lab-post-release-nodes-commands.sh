#!/bin/bash

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # Also needs SHARED_DIR to be set appropriately (e.g., to the same dir used by the pre-reserve-nodes step tested earlier)
  export AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op CLUSTER_PROFILE_DIR=~/.ssh
fi

set -o nounset
set -o errexit
set -o pipefail

if [ -z "${AUX_HOST}" ]; then
    echo "AUX_HOST is not filled. Failing."
    exit 1
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/packet-ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "$CLUSTER_NAME" << 'EOF'
BUILD_USER=ci-op
BUILD_ID="$1"

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

sed -i "/,${BUILD_ID},${BUILD_USER},/d" /etc/hosts_pool_reserved
sed -i "/,${BUILD_ID},${BUILD_USER},/d" /etc/vips_reserved

echo "Releasing lock $LOCK_FD ($LOCK)"
flock -u $LOCK_FD

EOF
