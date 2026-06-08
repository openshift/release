#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0

STATIC_IPS="${SHARED_DIR}"/static-ip-hosts.txt
static_ips=$(yq-go r "$STATIC_IPS" 'hosts.*.networkDevice.ipAddrs.*' | awk -F "/" '{print $1}')
nodes_list=$(oc get nodes -ojson | jq -r '.items[].metadata.name')

for node in $nodes_list; do
    node_check_result=1
    node_ip=$(oc get nodes "$node" -o=jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    for static_ip in $static_ips; do
        if [[ "$static_ip" == "$node_ip" ]]; then
            echo "Pass: passed to check static IP: $node_ip on node: ${node}"
            node_check_result=0
            break
        fi
    done
    if [[ $node_check_result == 1 ]]; then
        echo "Fail: fail to check static IP: $node_ip on node: ${node}"
        check_result=$((check_result + 1))
    fi
done
exit "${check_result}"
