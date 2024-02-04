#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-46245"

echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

# Check all virtual machines of cluster diskType are thin
IFS=' ' read -r -a node_names <<<"$(oc get machines -n openshift-machine-api -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalDNS")].address}')"
for node_name in "${node_names[@]}"; do
    if govc vm.info -json node_name | grep -i "\"ThinProvisioned\": true"; then
        echo "Pass: check $node_name diskType is thin"
    else
        echo "Fail: check $node_name diskType is thin"
        exit 1
    fi
done

# Restore
