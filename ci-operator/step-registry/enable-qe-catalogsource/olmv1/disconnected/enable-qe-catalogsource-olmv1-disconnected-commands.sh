#!/bin/bash
set -u

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}


function disable_default_catalogsource () {
    ocp_version=$(oc get -o jsonpath='{.status.desired.version}' clusterversion version)
    major_version=$(echo ${ocp_version} | cut -d '.' -f1)
    minor_version=$(echo ${ocp_version} | cut -d '.' -f2)
    if [[ "X${major_version}" == "X4" && -n "${minor_version}" && "${minor_version}" -gt 17 ]]; then
        echo "disable olmv1 default clustercatalog"
        run_command "oc patch clustercatalog openshift-certified-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        run_command "oc patch clustercatalog openshift-redhat-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        run_command "oc patch clustercatalog openshift-redhat-marketplace -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        run_command "oc patch clustercatalog openshift-community-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        run_command "oc get clustercatalog"        
    fi
}

#################### Main #######################################
run_command "oc whoami"
run_command "oc version -o yaml"

disable_default_catalogsource


