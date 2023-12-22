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

instance_name="${CLUSTER_NAME}-kp"
ibmcloud resource service-instance-create ${instance_name} kms tiered-pricing ${region}

id=$(ibmcloud resource service-instance ${instance_name} --id -q | awk '{print $2}')
echo "$(jq --arg idarg "$id" '. += {"id": $idarg}' $key_file)" > $key_file

export KP_INSTANCE_ID=${id}

key_meterial=$(openssl rand -base64 32)
key_name="${instance_name}-key"
tmpFile=$(mktemp)
ibmcloud kp key create ${key_name} -k ${key_meterial} -o json > ${tmpFile}

keyCRN=$(jq -r .crn $tmpFile)

keyID=$(jq -r .id $tmpFile)
echo "$(jq --arg idarg "$keyID" '. += {"keyID": $idarg}' $key_file)" > $key_file

cat ${key_file}

cat > "${SHARED_DIR}/ibm_kpKey.yaml" << EOF
platform:
  ibmcloud:
    defaultMachinePlatform:
      bootVolume:
        encryptionKey: "${keyCRN}"
    resourceGroupName: ${resource_group}
EOF