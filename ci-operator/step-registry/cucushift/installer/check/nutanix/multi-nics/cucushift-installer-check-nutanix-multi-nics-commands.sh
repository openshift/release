#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
    NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
    NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi
declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
# shellcheck disable=SC1090
source "${NUTANIX_AUTH_PATH}"

pc_url="https://${prism_central_host}:${prism_central_port}"
api_ep="${pc_url}/api/nutanix/v3/vms/list"
un="${prism_central_username}"
pw="${prism_central_password}"

function check_multi_nics() {
    data="{
        \"filter\":\"vm_name==$node\"
    }"
    node_json=$(curl -ks -u "${un}":"${pw}" -X POST "${api_ep}" -H "Content-Type: application/json" -d @- <<<"${data}")
    nic_list_length=$(echo "${node_json}" | jq -r '.entities[].status.resources.nic_list | length')
    if [[ $nic_list_length == 2 ]]; then
        echo "Pass: passed to check node $node nics"
    else
        echo "Fail: failed to check node $node nics"
        check_result=$((check_result + 1))
    fi
}

IFS=' ' read -r -a nodes_list <<<"$(oc get nodes -ojson | jq -r '.items[].metadata.name' | xargs)"

for node in "${nodes_list[@]}"; do
    check_multi_nics "$node"
done

exit "${check_result}"
