#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'post_actions' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"


echo "TEST_OBJECT: $TEST_OBJECT"
OUT_SELECT=${SHARED_DIR}/select.json
OUT_SELECT_DICT=${SHARED_DIR}/select.dict.json
OUT_RESULT=${SHARED_DIR}/result.json
echo '{}' > "$OUT_RESULT"

IC_COMPUTE_NODE_COUNT=2
IC_CONTROL_PLANE_NODE_COUNT=3

function is_empty() {
  local v="$1"
  if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
    return 0
  fi
  return 1
}

if [ ! -f "${OUT_SELECT}" ]; then
  echo "ERROR: Not found OUT_SELECT file."
  exit 1
fi

if [ ! -f "${OUT_SELECT_DICT}" ]; then
  echo "ERROR: Not found OUT_SELECT_DICT file."
  exit 1
fi

function current_date() { date -u +"%Y-%m-%d %H:%M:%S%z"; }

function update_result() {
  local k=$1
  local v=${2:-}
  cat <<< "$(jq -r --argjson kv "{\"$k\":\"$v\"}" '. + $kv' "$OUT_RESULT")" > "$OUT_RESULT"
}

function post_actions() {
  set +e

  current_time=$(date +%s)

  echo "Copying kubeconfig and metadata.json to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"

  echo "Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  echo "Copying install log and removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${INSTALL_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"

  # Writing result
  # "Bucket": "$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.bucket')",
  # "JobUrlPrefix": "$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.job_url_prefix')",
  
  update_result "Region" "${REGION}"
  update_result "CPType" "${CONTROL_PLANE_INSTANCE_TYPE}"
  update_result "CPFamily" "${CONTROL_PLANE_INSTANCE_TYPE_FAMILY}"
  update_result "CPZone" "${CONTROL_PLANE_INSTANCE_TYPE_ZONE}"
  update_result "CType" "${COMPUTE_INSTANCE_TYPE}"
  update_result "CFamily" "${COMPUTE_INSTANCE_TYPE_FAMILY}"
  update_result "CZone" "${COMPUTE_INSTANCE_TYPE_ZONE}"
  update_result "Arch" "${ARCH}"
  update_result "Install" "${INSTALL_RESULT}"
  update_result "CreatedDate" "${CREATED_DATE}"
  update_result "Job" "$(echo "${JOB_SPEC}" | jq -r '.job')"
  update_result "BuildID" "$(echo "${JOB_SPEC}" | jq -r '.buildid')"
  update_result "RowUpdated" "$(current_date)"

  echo "RESULT:"
  jq -r . "${OUT_RESULT}"

  # save JOB_SPEC to ARTIFACT_DIR for debugging
  echo "${JOB_SPEC}" | jq -r . > ${ARTIFACT_DIR}/JOB_SPEC.json

}

# set the parameters we'll need as env vars
export AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

# creating cluster

SSH_PUB_KEY=$(< "${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(< "${CLUSTER_PROFILE_DIR}/pull-secret")

REGION="$(jq -r '.Region' "${OUT_SELECT_DICT}")"
ARCH="$(jq -r '.Arch' "${OUT_SELECT_DICT}")"

CONTROL_PLANE_INSTANCE_TYPE="$(jq -r '.CPType' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_INSTANCE_TYPE_FAMILY="$(jq -r '.CPFamily' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_INSTANCE_TYPE_ZONE="$(jq -r '.CPZone' "${OUT_SELECT_DICT}")"

COMPUTE_INSTANCE_TYPE="$(jq -r '.CType' "${OUT_SELECT_DICT}")"
COMPUTE_INSTANCE_TYPE_FAMILY="$(jq -r '.CFamily' "${OUT_SELECT_DICT}")"
COMPUTE_INSTANCE_TYPE_ZONE="$(jq -r '.CZone' "${OUT_SELECT_DICT}")"

# Get ARCH
if is_empty "$ARCH"; then
  # Default ARCH is determined by each plarform.
  # For most of cased, default is arm.
  # For the resgions which do not support arm64, then set amd64
  ARCH="amd64"
  if [[ "${TEST_OBJECT}" == "Regions" ]]; then
    checked_instance_type="Standard_D4ps_v5"
  elif [[ "${TEST_OBJECT}" == "InstanceTypes" ]]; then
    checked_instance_type="${CONTROL_PLANE_INSTANCE_TYPE}"
  else
    echo "Unsuupported TEST_OBJECT: ${TEST_OBJECT}"
    exit 1
  fi
  echo "Debug CONTROL_PLANE_INSTANCE_TYPE: ${CONTROL_PLANE_INSTANCE_TYPE}"
  echo "Debug OUT_SELECT_DICT: $(cat ${OUT_SELECT_DICT})"
  cpu_arch=$(az vm list-skus --size ${checked_instance_type} --location ${REGION} --query "[].capabilities[?name=='CpuArchitectureType'].value" -otsv)
  if [[ "${cpu_arch}" == "Arm64" ]]; then
    ARCH="arm64"
  fi
fi

echo "Creating cluster in region ${REGION}:"
echo "ARCH: $ARCH"
echo "CONTROL_PLANE_INSTANCE*: $CONTROL_PLANE_INSTANCE_TYPE $CONTROL_PLANE_INSTANCE_TYPE_FAMILY"
echo "COMPUTE_INSTANCE*: $COMPUTE_INSTANCE_TYPE $COMPUTE_INSTANCE_TYPE_FAMILY"

INSTALL_RESULT=""
CREATED_DATE="$(current_date)"

function create_install_config() {
  local cluster_name=$1
  local install_dir=$2

  local config
  config=${install_dir}/install-config.yaml

  cat > "${config}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: ${ARCH}
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: ${IC_COMPUTE_NODE_COUNT}
controlPlane:
  architecture: ${ARCH}
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: ${IC_CONTROL_PLANE_NODE_COUNT}
metadata:
  creationTimestamp: null
  name: ${cluster_name}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform: {}
publish: External
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
}

# Check confidentialVM instance type
if [[ "${TEST_OBJECT}" == "InstanceTypes" ]]; then
  confidential_type=$(az vm list-skus --size ${CONTROL_PLANE_INSTANCE_TYPE} --location ${REGION} --query "[].capabilities[?name=='ConfidentialComputingType'].value" -otsv)
  if [[ -n "${confidential_type}" ]]; then
      echo "Instance type ${CONTROL_PLANE_INSTANCE_TYPE} is confidential VMs, configure confidentialVM settings"
  fi  
fi

ret=0

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

echo "--- Create install-config ---"

create_install_config "${CLUSTER_NAME}" "${INSTALL_DIR}"
CONFIG="${INSTALL_DIR}"/install-config.yaml

# Patch region
export REGION
yq-v4 eval -i '.platform.azure.region = env(REGION)' "${CONFIG}"

# Patch baseDomainResourceGroupName
export BASE_DOMAIN_RESOURCE_GROUP
yq-v4 eval -i '.platform.azure.baseDomainResourceGroupName = env(BASE_DOMAIN_RESOURCE_GROUP)' "${CONFIG}"

# Patch instance type
if [[ ${CONTROL_PLANE_INSTANCE_TYPE} != "" ]]; then
  export CONTROL_PLANE_INSTANCE_TYPE
  yq-v4 eval -i '.controlPlane.platform.azure.type = env(CONTROL_PLANE_INSTANCE_TYPE)' "${CONFIG}"
  if ! is_empty "${CONTROL_PLANE_INSTANCE_TYPE_ZONE}"; then
    CP_ZONE=$(echo ${CONTROL_PLANE_INSTANCE_TYPE_ZONE} | jq -Rc 'split(" ") | map(select(. != ""))')
    export CP_ZONE
    yq-v4 eval -i '.controlPlane.platform.azure.zones = env(CP_ZONE)' "${CONFIG}"
  fi

  # check if it is confidentialVM suppported
  cp_confidential_type=$(az vm list-skus --size ${CONTROL_PLANE_INSTANCE_TYPE} --location ${REGION} --query "[].capabilities[?name=='ConfidentialComputingType'].value" -otsv)
  if [[ -n "${cp_confidential_type}" ]]; then
    echo "Instance type ${CONTROL_PLANE_INSTANCE_TYPE} is confidential VMs with type ${cp_confidential_type}, configure confidentialVM settings"
    PATCH="/tmp/install-config-security-cp.yaml.patch"
    cat > "${PATCH}" << EOF
controlPlane:
  platform:
    azure:
      encryptionAtHost: false
      settings:
        securityType: ConfidentialVM
        confidentialVM:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
      osDisk:
        securityProfile:
          securityEncryptionType: VMGuestStateOnly
EOF
    yq-go m -x -i "${CONFIG}" "${PATCH}"
  fi
fi

if [[ ${COMPUTE_INSTANCE_TYPE} != "" ]]; then
  export COMPUTE_INSTANCE_TYPE
  yq-v4 eval -i '.compute[0].platform.azure.type = env(COMPUTE_INSTANCE_TYPE)' "${CONFIG}"
  if ! is_empty "${COMPUTE_INSTANCE_TYPE_ZONE}"; then
    C_ZONE=$(echo ${COMPUTE_INSTANCE_TYPE_ZONE} | jq -Rc 'split(" ") | map(select(. != ""))')
    export C_ZONE
    yq-v4 eval -i '.compute[0].platform.azure.zones = env(C_ZONE)' "${CONFIG}"
  fi

  # check if it is confidentialVM suppported
  c_confidential_type=$(az vm list-skus --size ${COMPUTE_INSTANCE_TYPE} --location ${REGION} --query "[].capabilities[?name=='ConfidentialComputingType'].value" -otsv)
  if [[ -n "${c_confidential_type}" ]]; then
    echo "Instance type ${COMPUTE_INSTANCE_TYPE} is confidential VMs with type ${c_confidential_type}, configure confidentialVM settings"
    PATCH="/tmp/install-config-security-compute.yaml.patch"
    cat > "${PATCH}" << EOF
compute:
- platform:
    azure:
      encryptionAtHost: false
      settings:
        securityType: ConfidentialVM
        confidentialVM:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
      osDisk:
        securityProfile:
          securityEncryptionType: VMGuestStateOnly
EOF
    yq-go m -x -i "${CONFIG}" "${PATCH}"
  fi
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"

cp "${CONFIG}" "${SHARED_DIR}"/install-config.yaml

# ---------------------------------------

echo "--- Create manifests ---"

set +e
openshift-install create manifests --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "Failed to create manifests. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created manifests."
fi

# ---------------------------------------

echo "--- Create ignition configs ---"

set +e
openshift-install create ignition-configs --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "Failed to ignition configs. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created ignition configs."
fi

# ---------------------------------------

echo "--- Create cluster ---"

set +e
openshift-install create cluster --dir ${INSTALL_DIR} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
install_ret="$?"
set -e

if [ $install_ret -ne 0 ]; then
  echo "Failed to create clusters. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created cluster."
  INSTALL_RESULT="PASS"
fi
ret=$((ret + install_ret))

echo "ret: $ret"
exit $ret
