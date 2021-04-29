#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup lso create disks command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF" |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeo pipefail

cd /root/dev-scripts
source common.sh

echo "Creating disks..."
for node in $(virsh list --name | grep ${CLUSTER_NAME}_worker ||
              virsh list --name | grep ${CLUSTER_NAME}_master); do
    for disk in sd{b..f}; do
        qemu-img create -f raw "/tmp/${node}-${disk}.img" 50G
        virsh attach-disk "${node}" "/tmp/${node}-${disk}.img" "${disk}"
    done
done
EOF
