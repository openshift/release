#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#pre create the dedicated hosts based on the ${SHARED_DIR}/dedicated_host.yaml and update "${SHARED_DIR}/dedicated_host.yaml
#save the dedicated host name for master nodes and worker nodes in "${SHARED_DIR}/dedicated_host"
#save the resource group name of the dedicated host group in "${SHARED_DIR}/ibmcloud_resource_group_dhg"

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
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

## create the dedicated host group and dedicated host, if succeed, save the dedicated host name to file"
## input parameter: the resource group of the dhg, dh profile, zone, name of the dh and the file which save the created dh name.
function createDH() {
    local rg=$1 dProfile=$2 zone=$3 dhName=$4 file=$5
    local tmp family class dhg ret
    tmp=$(${IBMCLOUD_CLI} is dedicated-host-profile $dProfile --output JSON | jq -r '.family +","+ .class')
    family=${tmp%,*}
    class=${tmp#*,}
    echo "family:" $family " class:" $class
    dhg="${dhName}g"
    run_command "${IBMCLOUD_CLI} is dedicated-host-group-create --zone $zone --family $family --class $class --name ${dhg}"
    
    ${IBMCLOUD_CLI} is dedicated-host-create --profile $dProfile --name $dhName --dhg $dhg --output JSON
    echo "${dhName}" > "${file}"

    waitingStatus ${dhName}
    ret=$?
    echo "${dhName} waiting status: ${ret}"
    run_command "${IBMCLOUD_CLI} is dedicated-host ${dhName}"

    if [[ "${ret}" != 0 ]]; then
        echo "ERROR: fail to create the dedicated host with profile $dProfile on zone: $zone resouce group:$rg"
        return 1
    fi

    return 0
}

# waiting the pending dh status changed
function waitingStatus() {
    local dh=$1 status
    COUNTER=0
    while [ $COUNTER -lt 20 ]
    do 
        sleep 10
        COUNTER=`expr $COUNTER + 20`
        status=$(${IBMCLOUD_CLI} is dh $dh --output JSON | jq -r ."lifecycle_state")
        if [[ "${status}" == "stable" ]]; then
            return 0
        fi
    done
    echo "get unexpected status of the dedicated host: ${status} !!"
    return 1
}

#####################################
##############Initialize#############
#####################################

dhProfile="bx2-host-152x608"
masterProfile="bx2-8x32"
workerProfile="bx2-4x16"

echo "the dh profile of the master nodes: ${dhProfile}; the dh profile of the worker nodes ${dhProfile}"

echo "$(date -u --rfc-3339=seconds) - Creating the Dedicated Host..."
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

dhName="${CLUSTER_NAME}-dh"

dhgRGFile=${SHARED_DIR}/ibmcloud_resource_group_dhg
dh_file=${SHARED_DIR}/dedicated_host

#####################################
#######create the dedicated host#####
#####################################
ibmcloud_login

#create the resouce group of the dedicated host group and saved in "${SHARED_DIR}/ibmcloud_resource_group_dhg"
rg_dhg="${CLUSTER_NAME}-dhrg"

echo "create resource group ... ${rg_dhg}"
"${IBMCLOUD_CLI}" resource group-create ${rg_dhg} || exit 1
echo "${rg_dhg}" >  ${dhgRGFile}

run_command "${IBMCLOUD_CLI} target -g $rg_dhg"

zone="${region}-${DEDICATEDHOST_ZONE}"
echo "use the zone defined with DEDICATEDHOST_ZONE: ${zone}"

createDH ${rg_dhg} ${dhProfile} ${zone} ${dhName} ${dh_file}

if [ $? != 0 ]; then
    echo "Fail to create the dedicated hosts !!"
    run_command "${IBMCLOUD_CLI} is dhs --resource-group-name ${rg_dhg}"
    exit 1
fi

#####################################
##Create dedicated host yaml file ###
#####################################
cat > "${SHARED_DIR}/dedicated_host.yaml" << EOF
controlPlane:
  platform:
    ibmcloud:
      type: ${masterProfile}
      zones: ["${zone}"]
      dedicatedHosts:
      - name: ${dhName}
compute:
- platform: 
    ibmcloud:
      type: ${workerProfile}
      zones: ["${zone}"]
      dedicatedHosts:
      - name: ${dhName}
EOF

#OCPBUGS-5906 [IPI-IBMCloud] fail to retrieve the dedicated host which is not in the cluster group when provisioning the worker nodes
cat >> "${SHARED_DIR}/dedicated_host.yaml" << EOF
platform:
  ibmcloud:
    resourceGroupName: ${rg_dhg}
EOF


cat "${SHARED_DIR}/dedicated_host.yaml"
