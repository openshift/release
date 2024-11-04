#!/bin/bash

set -e
set -u
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function add_redhat_registry_auth () {
    # get the registry configures of the cluster
    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    if [[ $ret -eq 0 ]]; then 
        redhat_auth_user=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.user')
        redhat_auth_password=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.password')
        registry_cred=`echo $redhat_auth_user:$redhat_auth_password | base64 -w 0`

        jq --argjson a "{\"regiustry.redhat.io\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson
        # Add redhat registry auth for the cluster
        run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson"; ret=$?
        if [[ $ret -eq 0 ]]; then
            check_mcp_status
            echo "Add redhat registry auth successfully."
	    return 0
        else
            echo "!!! fail to add redhat registry auth"
            return 1
        fi
    else
        echo "Can not extract Auth of the cluster"
        echo "!!! fail to add redhat registry auth"
        return 1
    fi
}

function check_mcp_status() {
    machineCount=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
    COUNTER=0
    while [ $COUNTER -lt 1200 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        updatedMachineCount=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
        if [[ ${updatedMachineCount} = "${machineCount}" ]]; then
            echo "MCP updated successfully"
            break
        fi
    done
    if [[ ${updatedMachineCount} != "${machineCount}" ]]; then
        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        return 1
    fi
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi 
add_redhat_registry_auth