#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0

if [[ -z ${CLUSTER_OS_IMAGE} ]]; then
    echo "CLUSTER_OS_IMAGE is not set, skip checking os-image setting"
    exit "${check_result}"
fi

echo "CLUSTER_OS_IMAGE is set, check boot os-image setting"

version_os_image=$(echo "$CLUSTER_OS_IMAGE" | cut -d / -f10)
nodes_list=$(oc get nodes -ojson | jq -r '.items[].metadata.name')
for node in $nodes_list; do
    if oc debug node/"$node" -n default -- chroot /host journalctl | grep "Booted osImageURL" | grep "$version_os_image"; then
        echo "Pass: passed to check node: $node boot os image $version_os_image"
    else
        echo "Fail: failed to check node: $node boot os image $version_os_image"
        check_result=$((check_result + 1))
    fi
done

exit "${check_result}"
