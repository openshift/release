#!/bin/bash

set -o nounset

error_handler() {
  echo "Error: ($1) occurred on $2"
}

trap 'error_handler $? $LINENO' ERR

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
echo "Invoking installation of UPI based heterogeneous VPC"
echo "BUILD ID - ${BUILD_ID}"
TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
echo "TRIMMED BUILD ID - ${TRIM_BID}"
OCP_VERSION=$(< "${SHARED_DIR}/OCP_VERSION")
OCP_CLEAN_VERSION=$(echo "${OCP_VERSION}" | awk -F. '{print $1"."$2}')
CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
export NAME_PREFIX="rdr-mac-${CLEAN_VERSION}"
WORKSPACE_NAME=$(<"${SHARED_DIR}"/WORKSPACE_NAME)
export WORKSPACE_NAME
VPC_NAME="${WORKSPACE_NAME}-vpc"
export VPC_NAME
POWERVS_SERVICE_INSTANCE_ID=$(< "${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID")
export POWERVS_SERVICE_INSTANCE_ID
BASTION_PRIVATE_IP=$(< "${SHARED_DIR}/BASTION_PRIVATE_IP")
export BASTION_PRIVATE_IP
BASTION_PUBLIC_IP=$(< "${SHARED_DIR}/BASTION_PUBLIC_IP")
export BASTION_PUBLIC_IP
KUBECONFIG="${SHARED_DIR}"/kubeconfig
export KUBECONFIG
echo "POWERVS_SERVICE_INSTANCE_ID:- ${POWERVS_SERVICE_INSTANCE_ID}"
echo "BASTION_PRIVATE_IP:- ${BASTION_PRIVATE_IP}"
echo "BASTION_PUBLIC_IP:- ${BASTION_PUBLIC_IP}"

POWERVS_REGION=$(< "${SHARED_DIR}/POWERVS_REGION")
POWERVS_ZONE=$(< "${SHARED_DIR}/POWERVS_ZONE")
VPC_REGION=$(< "${SHARED_DIR}/VPC_REGION")
VPC_ZONE=$(< "${SHARED_DIR}/VPC_ZONE")
echo "POWERVS_REGION:- ${POWERVS_REGION}"
echo "POWERVS_ZONE:- ${POWERVS_ZONE}"
echo "VPC_REGION:- ${VPC_REGION}"
echo "VPC_ZONE:- ${VPC_ZONE}"
export POWERVS_REGION
export POWERVS_ZONE
export VPC_REGION
export VPC_ZONE

if [ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string"
  exit 1
fi

if [ "${ADDITIONAL_WORKERS}" == "0" ]
then
  echo "No additional workers requested"
  exit 0
fi

function ic() {
  HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
}

NO_OF_RETRY=${NO_OF_RETRY:-"3"}

function retry {
  cmd=$1
  for retry in $(seq 1 "$NO_OF_RETRY"); do
    echo "Attempt: $retry/$NO_OF_RETRY"
    ret_code=0
    $cmd || ret_code=$?
    if [ $ret_code = 0 ]; then
      break
    elif [ "$retry" == "$NO_OF_RETRY" ]; then
      error_handler "All retry attempts failed! Please try running the script again after some time" $ret_code
    else
      sleep 30
    fi
  done
}

function setup_jq() {
  if [ -z "$(command -v jq)" ]
  then
    echo "jq is not installed, proceed to installing jq"
    curl -L "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux64" -o /tmp/jq && chmod +x /tmp/jq
  fi
}

function setup_ibmcloud_cli() {
  if [ -z "$(command -v ibmcloud)" ]
  then
    echo "ibmcloud CLI doesn't exist, installing"
    curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
  fi

  ic config --check-version=false
  ic version
}

function setup_terraform_cli() {
  if [ -z "$(command -v terraform)" ]
  then
    echo "terraform CLI doesn't exist, installing"
  fi
  curl -L "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o "${IBMCLOUD_HOME_FOLDER}"/terraform.zip
  cd "${IBMCLOUD_HOME_FOLDER}" || true
  unzip -o "${IBMCLOUD_HOME_FOLDER}"/terraform.zip
  ${IBMCLOUD_HOME_FOLDER}/terraform version
}

function cleanup_ibmcloud_vpc() {
  cos_name="${NAME_PREFIX}-mac-intel-cos"

  echo "Cleaning up Instances"
  for INS in $(ic is instances --output json | jq -r '.[].id')
  do
    VALID_INS=$(ic is instance "${INS}" --output json | jq -r '. | select(.vpc.name == "'${VPC_NAME}'")')
    if [ -n "${VALID_INS}" ]
    then
      retry "ic is ind ${INS} --force"
      sleep 60
    fi
  done

  echo "Cleaning up COS Instances"
  VALID_COS=$(ic resource service-instances 2> /dev/null | grep "${cos_name}" || true)
  if [ -n "${VALID_COS}" ]
  then
    for COS in $(ic resource service-instance "${cos_name}" --output json -q | jq -r '.[].guid')
    do
      retry "ic resource service-instance-delete ${COS} --force --recursive"
    done
  fi

  echo "Done cleaning up prior runs"
}

function get_ready_nodes_count() {
  oc get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
  grep -c -E ",True$"
}

function setup_mac_vpc_workspace(){
  # Before the vpc is created, download the automation code
  cd "${IBMCLOUD_HOME_FOLDER}" || true
  curl -sL "https://github.com/IBM/ocp4-upi-compute-powervs-ibmcloud/archive/refs/heads/release-${OCP_CLEAN_VERSION}.tar.gz" -o ./ocp4-mac-vpc.tar.gz
  tar -xf "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc.tar.gz
  mv ocp4-upi-compute-powervs-ibmcloud-release-"${OCP_CLEAN_VERSION}" ocp4-mac-vpc || true
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc || true
  ${IBMCLOUD_HOME_FOLDER}/terraform init
}

function create_mac_vpc_tf_varfile(){
  export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-privatekey
  export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-publickey

  if [ -z "${PUBLIC_KEY_FILE}" ]
  then
    echo "ERROR: PUBLIC KEY FILE is not set"
    return
  fi
  if [ -z "${PRIVATE_KEY_FILE}" ]
  then
    echo "ERROR: PRIVATE KEY FILE is not set"
    return
  fi

  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/ || true
  cp "${PUBLIC_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/data/id_rsa.pub
  cp "${PRIVATE_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/data/id_rsa

  cat <<EOF >${IBMCLOUD_HOME_FOLDER}/ocp4-mac-vpc/var-mac-vpc.tfvars
ibmcloud_api_key = "${IBMCLOUD_API_KEY}"
vpc_name   = "${VPC_NAME}"
vpc_region = "${VPC_REGION}"
vpc_zone   = "${VPC_ZONE}"
powervs_service_instance_id = "${POWERVS_SERVICE_INSTANCE_ID}"
powervs_region              = "${POWERVS_REGION}"
powervs_zone                = "${POWERVS_ZONE}"
worker_1 = { count = "${ADDITIONAL_WORKERS}", profile = "cx2-8x16", "zone" = "${VPC_REGION}-1" }
worker_2 = { count = "0", profile = "cx2-8x16", "zone" = "${VPC_REGION}-2" }
worker_3 = { count = "0", profile = "cx2-8x16", "zone" = "${VPC_REGION}-3" }
powervs_bastion_ip         = "${BASTION_PUBLIC_IP}"
powervs_bastion_private_ip = "${BASTION_PRIVATE_IP}"
powervs_machine_cidr = "192.168.200.0/24"
EOF

  # PowerVS cluster profile requires powervs-config.json
  cat <<EOF >"/tmp/powervs-config.json"
{"id":"empty","apikey":"${IBMCLOUD_API_KEY}","region":"empty","zone":"empty","serviceinstance":"empty","resourcegroup":"empty"}
EOF
  cp "/tmp/powervs-config.json" "${SHARED_DIR}"/powervs-config.json

  cp "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/var-mac-vpc.tfvars "${SHARED_DIR}"/var-mac-vpc.tfvars
  cat "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/var-mac-vpc.tfvars
}

function cleanup_duplicate_sshkeys() {
  echo "Cleaning up duplicate SSH Keys"
  PUB_KEY_DATA=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)
  for KEY in $(ic is keys --resource-group-name "${RESOURCE_GROUP}" --output json | jq -r '.[].id')
  do
    KEY_DATA=$(ic is key "${KEY}" --output json | jq -r '.public_key')
    if [ "${KEY_DATA}" == "${PUB_KEY_DATA}" ]
    then
      echo "Duplicate key found"
      retry "ic is keyd ${KEY} -f"
      echo "Duplicate key deleted"
      sleep 10
    fi
  done
}

function create_mac_vpc_resources() {
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/ || true
  "${IBMCLOUD_HOME_FOLDER}"/terraform apply -var-file var-mac-vpc.tfvars -auto-approve || true
  cp "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/terraform.tfstate "${SHARED_DIR}"/terraform-mac-vpc.tfstate
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
function wait_for_nodes_readiness()
{
  local expected_nodes=${1}
  local max_retries=${2:-10}
  local period=${3:-5}
  for i in $(seq 1 "${max_retries}") max
  do
    if [ "${i}" == "max" ]
    then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      return 1
    fi
    sleep "${period}m"
    ready_nodes=$(get_ready_nodes_count)
    if [ "${ready_nodes}" == "${expected_nodes}" ]
    then
      echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
      return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

EXPECTED_NODES=$(( $(get_ready_nodes_count) + ADDITIONAL_WORKERS ))

echo "Cluster type is ${CLUSTER_TYPE}"

case "$CLUSTER_TYPE" in
*powervs*)
  if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" == "amd64" ]
  then
    PATH=${PATH}:/tmp
    mkdir -p "${IBMCLOUD_HOME_FOLDER}"
    export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"

    setup_jq
    setup_ibmcloud_cli
    setup_terraform_cli
    IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IBMCLOUD_API_KEY

    echo "Invoking upi install heterogeneous vpc for ${VPC_NAME}"
    echo "Logging into IBMCLOUD"
    ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
    ic plugin install -f vpc-infrastructure tg-cli power-iaas

    cleanup_ibmcloud_vpc
    setup_mac_vpc_workspace
    create_mac_vpc_tf_varfile
    cleanup_duplicate_sshkeys
    create_mac_vpc_resources
  fi
;;
*)
  echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

if [ -f "${SHARED_DIR}"/terraform-mac-vpc.tfstate ]
then
  echo "Wait for the nodes to become ready..."
  wait_for_nodes_readiness ${EXPECTED_NODES}
  ret="$?"
  if [ "${ret}" != "0" ]
  then
    echo "Some errors occurred, exiting with ${ret}."
    exit "${ret}"
  fi
fi

exit 0
