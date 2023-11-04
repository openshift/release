#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Random select the dedicated host profile and based on the profile get the vm type.
#Known Issues: 
# OCPBUGS-5906 [IPI-IBMCloud] fail to retrieve the dedicated host which is not in the cluster group when provisioning the worker nodes
# OCPBUGS-18925 [IPI-IBMCloud] ] fail to use vx2d-host-176x2464 profile with dedicated host in install-config

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output
    region="${LEASED_RESOURCE}"
    export region
    echo "Try to login..."
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

#random selete the dh profile, OCPBUGS-18925 blocked use "very-high-memory"
#if need specify the dh profile to test, just change the return value.
function randomGetDHProfile {
    local all_profiles profiles selected_id proTotal
    all_profiles=$(${IBMCLOUD_CLI} is dhps --output JSON | jq -r '.[] | select(.family | endswith("high-memory") | not) | .name')
    mapfile -t profiles <<< "${all_profiles}"
    proTotal=${#profiles[@]}
    selected_id=$((RANDOM % ${proTotal}))
    echo ${profiles[$selected_id]}
}

#####################################
##############Initialize#############
#####################################
ibmcloud_login

#####################################
##random select the dedicated host profile ##
#####################################

echo "$(date -u --rfc-3339=seconds) - Random select the Dedicated Host..."

dhProfileMaster=$(randomGetDHProfile)
echo "random selected ${dhProfileMaster} for master nodes"
class1=${dhProfileMaster%%-*}

dhProfileWorker=$(randomGetDHProfile)
echo "random selected ${dhProfileWorker} for worker nodes"
class2=${dhProfileWorker%%-*}

masterProfile=$(${IBMCLOUD_CLI} is instance-profiles -q | awk '(NR>1) {print $1}' | grep "${class1}-8x")
workerProfile=$(${IBMCLOUD_CLI} is instance-profiles -q | awk '(NR>1) {print $1}' | grep "${class2}-4x")

zone="${region}-${DEDICATEDHOST_ZONE}"
echo "use the zone defined with DEDICATEDHOST_ZONE: ${zone}"
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
      - profile: ${dhProfileMaster}
compute:
- platform: 
    ibmcloud:
      type: ${workerProfile}
      zones: ["${zone}"]
      dedicatedHosts:
      - profile: ${dhProfileWorker}
EOF

cat "${SHARED_DIR}/dedicated_host.yaml"