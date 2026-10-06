#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#pre create the iam service-id and based it create the iam service api key for ibmcloud-ipi-minimal-permission test
# based on doc https://docs.openshift.com/container-platform/4.14/installing/installing_ibm_cloud_public/installing-ibm-cloud-account.html#required-access-policies-ibm-cloud_installing-ibm-cloud-account

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output
    region="${LEASED_RESOURCE}"
    export region
    echo "Try to login..."
    "${IBMCLOUD_CLI}" config --check-version=false
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

#####################################
##############Initialize#############
#####################################
ibmcloud_login

serviceName=$(cat "${SHARED_DIR}/iam_service_name")
run_command "${IBMCLOUD_CLI} iam service-id-delete ${serviceName} -f"
