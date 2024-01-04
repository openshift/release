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

function createServicePolicy {
  $IBMCLOUD_CLI iam service-policy-create "$1" --roles "$2" --service-name "$3"
}
#####################################
##############Initialize#############
#####################################
ibmcloud_login

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
serviceName="${CLUSTER_NAME}-perm"
keyName="${serviceName}-key"
keyFile=$(mktemp)

## create the server id
run_command "${IBMCLOUD_CLI} iam service-id-create ${serviceName}"
echo ${serviceName} > "${SHARED_DIR}/iam_service_name"
run_command "${IBMCLOUD_CLI} iam service-id ${serviceName}"


## create the service key
run_command "${IBMCLOUD_CLI} iam service-api-key-create ${keyName} ${serviceName} -d 'the key for minimal permission test in ${CLUSTER_NAME}' --file ${keyFile}"

if [[ ! -f "${keyFile}" ]]; then
  echo "ERROR Fail to find the file which saved the service api key, abort." && exit 1
fi

echo "Reading api key info from ${keyFile}..."

newKey=$(cat ${keyFile} | jq -r .apikey)

if [ -z "${newKey}" ]; then
  echo "ERROR: fail to get the new key from ${keyFile}, abort." && exit 1
fi

echo "create the required access policies based on the required-access-policies-ibm-cloud_installing-ibm-cloud-account doc and assign them to the service ID ${serviceName} ..."

createServicePolicy ${serviceName} "Viewer,Operator,Editor,Administrator,Reader,Writer,Manager" "dns-svcs"
createServicePolicy ${serviceName} "Reader,Writer,Manager,Viewer,Operator,Editor,Administrator" "is"
createServicePolicy ${serviceName} "Viewer,Operator,Editor,Administrator,Reader,Writer,Manager,Object Writer,Content Reader,Object Reader" "cloud-object-storage"
## Identity and Access Management
createServicePolicy ${serviceName} "Viewer,Operator,Editor,Administrator" "iam-svcs"
## IAM Identity Service
createServicePolicy ${serviceName} "Viewer,Operator,Editor,Administrator,Service ID creator" "iam-identity"
## Internet Services
createServicePolicy ${serviceName} "Viewer,Operator,Editor,Administrator,Reader,Writer,Manager" "internet-svcs"

${IBMCLOUD_CLI} iam service-policy-create ${serviceName} --roles "Viewer,Operator,Editor,Administrator" --resource-type resource-group

echo "list all the access policies for the service ID ${serviceName} ..."
run_command "${IBMCLOUD_CLI} iam service-policies ${serviceName}"

echo ${newKey} > "${SHARED_DIR}/ibmcloud-min-permission-api-key"
