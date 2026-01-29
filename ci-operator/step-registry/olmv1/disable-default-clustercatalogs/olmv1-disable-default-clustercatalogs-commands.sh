#!/bin/bash
set -u

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function patch_clustercatalog_if_exists() {
    local catalog_name="$1"
    local retry_count=0
    local max_retries=3

    while [[ $retry_count -lt $max_retries ]]; do
        set +e
        error_output=$(oc get clustercatalog "$catalog_name" 2>&1)
        get_exit_code=$?
        set -e

        if [[ $get_exit_code -eq 0 ]]; then
            # Resource exists, patch it
            run_command "oc patch clustercatalog $catalog_name -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
            return 0
        elif echo "$error_output" | grep -qiE "(NotFound|not found|could not find)"; then
            # Resource doesn't exist, this is expected in some versions
            echo "$catalog_name clustercatalog does not exist, skipping..."
            return 0
        else
            # Some other error occurred
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                echo "Warning: failed to check $catalog_name clustercatalog (attempt $retry_count/$max_retries): $error_output"
                echo "Retrying in 5 seconds..."
                sleep 5
            else
                echo "Error: failed to check $catalog_name clustercatalog after $max_retries attempts: $error_output"
                return 1
            fi
        fi
    done
}

function disable_default_clustercatalog () {
    ocp_version=$(oc get -o jsonpath='{.status.desired.version}' clusterversion version)
    major_version=$(echo ${ocp_version} | cut -d '.' -f1)
    minor_version=$(echo ${ocp_version} | cut -d '.' -f2)
    if [[ "X${major_version}" == "X4" && -n "${minor_version}" && "${minor_version}" -gt 17 ]]; then
        echo "disable olmv1 default clustercatalogs"
        run_command "oc patch clustercatalog openshift-certified-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        run_command "oc patch clustercatalog openshift-redhat-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        # openshift-redhat-marketplace was removed in 4.22, so check if it exists first
        patch_clustercatalog_if_exists "openshift-redhat-marketplace" || return 1
        run_command "oc patch clustercatalog openshift-community-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        sleep 1
        run_command "oc get clustercatalog"
    fi
}

#################### Main #######################################
run_command "oc whoami"
run_command "oc version -o yaml"

disable_default_clustercatalog


