#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM


if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

OUT_SELECT=${SHARED_DIR}/select.json
OUT_SELECT_DICT=${SHARED_DIR}/select.dict.json
OUT_RESULT=${SHARED_DIR}/result.json
echo '{}' > "$OUT_RESULT"

IC_COMPUTE_NODE_COUNT=2
IC_CONTROL_PLANE_NODE_COUNT=3
DefaultCPUNumber=4

local zones_count=3

if [ ! -f "${OUT_SELECT}" ]; then
  echo "ERROR: Not found OUT_SELECT file."
  exit 1
fi

if [ ! -f "${OUT_SELECT_DICT}" ]; then
  echo "ERROR: Not found OUT_SELECT_DICT file."
  exit 1
fi


function is_empty() {
  local v="$1"
  if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
    return 0
  fi
  return 1
}

function current_date() { date -u +"%Y-%m-%d %H:%M:%S%z"; }

function update_result() {
  local k=$1
  local v=${2:-}
  cat <<< "$(jq -r --argjson kv "{\"$k\":\"$v\"}" '. + $kv' "$OUT_RESULT")" > "$OUT_RESULT"
}

function create_install_config() {
  local cluster_name=$1
  local install_dir=$2
  local master_type=$3
  local compute_type=$4
  
  local r_zones=("${REGION}-1" "${REGION}-2" "${REGION}-3")
  local zones="${R_ZONES[*]:0:${ZONES_COUNT}}"
  local zones_str="[ ${zones// /, } ]"
  local zones_raw=$(ibmcloud is zones ${REGION} -q | awk '(NR>1) {print $1}')

  local formatted_zones="[$(echo "$zones_raw" | paste -sd, - | sed 's/,/, /g')]"

  echo "$formatted_zones"

  local config
  config=${install_dir}/install-config.yaml

  cat > "${config}" << EOF
apiVersion: v1
baseDomain: ${IBMCLOUD_BASE_DOMAIN}
credentialsMode: Manual
compute:
- architecture: ${ARCH}
  name: worker
  platform:
    ibmcloud:
      type: ${compute_type}
      zones: ${formatted_zones}
  replicas: ${IC_COMPUTE_NODE_COUNT}
controlPlane:
  architecture: ${ARCH}
  name: master
  platform:
    ibmcloud:
      type: ${master_type}
      zones: ${formatted_zones}
  replicas: ${IC_CONTROL_PLANE_NODE_COUNT}
metadata:
  name: ${cluster_name}
platform:
  ibmcloud:
     region: ${REGION}
publish: External
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
  return ${config}
}



# IBM Cloud CLI login
function ibmcloud_login {
  export IBMCLOUD_CLI=ibmcloud
  export IBMCLOUD_HOME=/output
  region="${1}"
  "${IBMCLOUD_CLI}" config --check-version=false
  echo "Try to login..."
  "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -q
  "${IBMCLOUD_CLI}" target -q
  echo "Login successful."
}

function getInstanceType {
  local instance_type=$1
  local declare -A instance_map

  instance_map=( 
      ["gx2"]=8 
      ["gx3"]=16 
      ["gx3d"]=24 
  )
  local cpu_number=${instance_map[${instance_type}]:-$DefaultCPUNumber}

  instance_type=$(ibmcloud is instance-profiles -q | grep ${ARCH} | grep "${instance_type}-${cpu_number}x" | awk '{print $1}')
  if [[ -z "$instance_type" ]]; then    
    echo "ERROR: No instance type found for family ${instance_type} cpu $cpu_number."
    return ""
  fi
  return "$instance_type"
}

# creating cluster

SSH_PUB_KEY=$(< "${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(< "${CLUSTER_PROFILE_DIR}/pull-secret")

IBMCLOUD_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/ibmcloud-cis-domain)"
if [[ -n "${BASE_DOMAIN}" ]]; then
  IBMCLOUD_BASE_DOMAIN="${BASE_DOMAIN}"
fi
REGION="$(jq -r '.Region' "${OUT_SELECT_DICT}")"
ARCH="$(jq -r '.Arch' "${OUT_SELECT_DICT}")"

CONTROL_PLANE_INSTANCE_TYPE="$(jq -r '.CPType' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_INSTANCE_TYPE_FAMILY="$(jq -r '.CPFamily' "${OUT_SELECT_DICT}")"

COMPUTE_INSTANCE_TYPE="$(jq -r '.CType' "${OUT_SELECT_DICT}")"
COMPUTE_INSTANCE_TYPE_FAMILY="$(jq -r '.CFamily' "${OUT_SELECT_DICT}")"

if is_empty "$ARCH" || [[ "${$ARCH,,}" == "amd64" ]]; then
  ARCH="amd64"
else then
  echo "ERROR: Unsupported arch ${ARCH}, exiting"
  exit 1
fi

if is_empty "REGION" || is_empty "$CONTROL_PLANE_INSTANCE_TYPE_FAMILY" ; then
  echo "ERROR: Region and control plane instance type family are required, exiting"
  exit 1
fi



ibmcloud_login "${REGION}"

allowlist_instance_types=
if is_empty "$CONTROL_PLANE_INSTANCE_TYPE" ; then
  CONTROL_PLANE_INSTANCE_TYPE=$(getInstanceType "$CONTROL_PLANE_INSTANCE_TYPE_FAMILY")
fi

if is_empty "$COMPUTE_INSTANCE_TYPE" ; then
  if is_empty "$COMPUTE_INSTANCE_TYPE_FAMILY"; then
    COMPUTE_INSTANCE_TYPE_FAMILY="$CONTROL_PLANE_INSTANCE_TYPE_FAMILY"
    echo "INFO: Compute instance type family is not set, use control plane instance type family ${COMPUTE_INSTANCE_TYPE_FAMILY} as default."
    COMPUTE_INSTANCE_TYPE=${CONTROL_PLANE_INSTANCE_TYPE}
  else
    COMPUTE_INSTANCE_TYPE=$(getInstanceType "$COMPUTE_INSTANCE_TYPE_FAMILY")
  fi
fi

if is_empty "${CONTROL_PLANE_INSTANCE_TYPE}" || is_empty "${COMPUTE_INSTANCE_TYPE}" ; then
  echo "ERROR: No instance type found for control plane ${CONTROL_PLANE_INSTANCE_TYPE_FAMILY} or compute plane ${COMPUTE_INSTANCE_TYPE_FAMILY} in region ${REGION}, exiting."
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Creating cluster in region ${REGION}:"
echo "$(date -u --rfc-3339=seconds) - ARCH: $ARCH"
echo "$(date -u --rfc-3339=seconds) - CONTROL_PLANE_INSTANCE*: $CONTROL_PLANE_INSTANCE_TYPE $CONTROL_PLANE_INSTANCE_TYPE_FAMILY"
echo "$(date -u --rfc-3339=seconds) - COMPUTE_INSTANCE*: $COMPUTE_INSTANCE_TYPE $COMPUTE_INSTANCE_TYPE_FAMILY"

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
INSTALL_DIR=/tmp/install_dir
mkdir -p ${INSTALL_DIR}

# ---------------------------------------
# Print openshift-install version
# ---------------------------------------

openshift-install version

# ---------------------------------------
# Create install-config
# ---------------------------------------

echo "$(date -u --rfc-3339=seconds) - Create install-config"


configFile=$(create_install_config "${CLUSTER_NAME}" "${INSTALL_DIR}" ${CONTROL_PLANE_INSTANCE_TYPE} ${COMPUTE_INSTANCE_TYPE})


echo "install-config.yaml:"
cat "${configFile}"
cp "${configFile}" "${SHARED_DIR}"/install-config.yaml