#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output   
    region="${LEASED_RESOURCE}"
    export region
    echo "Try to login..."
    "${IBMCLOUD_CLI}" config --check-version=false
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
    ibmcloud plugin list
}


function create_resource_group() {
    local rg="$1"
    echo "create resource group ... ${rg}"
    "${IBMCLOUD_CLI}" resource group-create ${rg} || return 1
    "${IBMCLOUD_CLI}" target -g ${rg} || return 1
}

function createKey() {
    local instance_name=$1
    local region=$2
    local keyInfoFile=$3
    local id key_name key_meterial tmpFile keyCRN keyID
    #echo -n "" > ${keyInfoFile}
    ibmcloud resource service-instance-create ${instance_name} kms tiered-pricing ${region}
    id=$(ibmcloud resource service-instance ${instance_name} --id -q | awk '{print $2}')
   
    key_name="${instance_name}-key"
    key_meterial=$(openssl rand -base64 32)
    tmpFile=$(mktemp)
    ibmcloud kp key create ${key_name} -k ${key_meterial} -i ${id} -o json > ${tmpFile}

    keyCRN=$(jq -r .crn $tmpFile)
    keyID=$(jq -r .id $tmpFile)

    jq -n \
      --arg id "$id" \
      --arg keyID "$keyID" \
      --arg keyCRN "$keyCRN" \
      '$ARGS.named' > "${keyInfoFile}"

    cat ${keyInfoFile} | jq
}

ibmcloud_login

## Create the instances for BYOK
echo "$(date -u --rfc-3339=seconds) - Creating the instance for BYOK..."

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

resource_group="${CLUSTER_NAME}-rg"

key_file="${SHARED_DIR}/ibmcloud_key.json"

create_resource_group ${resource_group}
cat >${key_file} <<EOF
{
  "resource_group": "${resource_group}"
}
EOF

echo "ControlPlane EncryptionKey: ${IBMCLOUD_CONTROL_PLANE_ENCRYPTION_KEY}"
echo "Compute EncryptionKey: ${IBMCLOUD_COMPUTE_ENCRYPTION_KEY}"
echo "DefaultMachinePlatform EncryptionKey: ${IBMCLOUD_DEFAULT_MACHINE_ENCRYPTION_KEY}"

dataFile=$(mktemp)
bakFile=$(mktemp)
if [[ "${IBMCLOUD_CONTROL_PLANE_ENCRYPTION_KEY}" == "true" ]]; then
  createKey "${CLUSTER_NAME}-kp-master" ${region} ${dataFile}
  jq --argjson idarg "$(< $dataFile)" '. += {"master": $idarg}' $key_file > ${bakFile}
  mv ${bakFile} ${key_file}
fi

if [[ "${IBMCLOUD_COMPUTE_ENCRYPTION_KEY}" == "true" ]]; then
  createKey "${CLUSTER_NAME}-kp-worker" ${region} ${dataFile}
  jq --argjson idarg "$(< $dataFile)" '. += {"worker": $idarg}' $key_file > ${bakFile}
  mv ${bakFile} ${key_file}
fi

if [[ "${IBMCLOUD_DEFAULT_MACHINE_ENCRYPTION_KEY}" == "true" ]]; then
  createKey "${CLUSTER_NAME}-kp-default" ${region} ${dataFile}
  jq --argjson idarg "$(< $dataFile)" '. += {"default": $idarg}' $key_file > ${bakFile}
  mv ${bakFile} ${key_file}
fi

echo "dump ${key_file}..."

cat ${key_file}
