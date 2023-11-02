#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

no_critical_check_result=0
echo "------ Checking that all ndoes are running Red Hat Enterprise Linux CoreOS ------"
nodes_list=$(oc get nodes -o json | jq -r '.items[].metadata.name')
for node in ${nodes_list}; do
    node_osimage=$(oc get node ${node} -o json | jq -r '.status.nodeInfo.osImage')
    if [[ "${node_osimage}" =~ "Red Hat Enterprise Linux CoreOS" ]]; then
        echo "INFO: node ${node} osimage: ${node_osimage}"
    else
        echo "ERROR: node ${node} gets unexpected os image: ${node_osimage}"
        no_critical_check_result=1
    fi
done

if [[ ${no_critical_check_result} == 1 ]]; then
    echo "ERROR: nodes os image check failed!"
    [[ "${EXIT_ON_INSTALLER_CHECK_FAIL}" == "yes" ]] && exit 1
fi

exit 0
