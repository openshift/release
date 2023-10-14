#!/bin/bash

set -o nounset

export KUBECONFIG=${SHARED_DIR}/kubeconfig

for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}');
do
    echo ">> $NODE"; oc debug node/"$NODE" -- chroot /host /bin/bash -c 'lsblk';
done

exit "${EXIT_CODE}"
