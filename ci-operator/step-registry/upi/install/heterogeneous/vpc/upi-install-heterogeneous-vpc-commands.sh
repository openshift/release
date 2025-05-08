#!/bin/bash

set -o nounset

error_handler() {
  echo "Error: (${1}) occurred on (${2})"
}

trap 'error_handler $? $LINENO' ERR

IBMCLOUD_HOME=/tmp/ibmcloud
export IBMCLOUD_HOME

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
export IBMCLOUD_HOME_FOLDER

export PATH=$PATH:/tmp:"${IBMCLOUD_HOME}"

echo "Invoking installation of UPI based heterogeneous VPC"
echo "BUILD ID - ${BUILD_ID}"
TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
echo "TRIMMED BUILD ID - ${TRIM_BID}"
OCP_VERSION=$(< "${SHARED_DIR}/OCP_VERSION")
OCP_CLEAN_VERSION=$(echo "${OCP_VERSION}" | awk -F. '{print $1"."$2}')
CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
export NAME_PREFIX="multi-arch-p-px-${CLEAN_VERSION}"
WORKSPACE_NAME=$(<"${SHARED_DIR}"/WORKSPACE_NAME)
export WORKSPACE_NAME
VPC_NAME="${WORKSPACE_NAME}"
export VPC_NAME
POWERVS_SERVICE_INSTANCE_ID=$(< "${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID")
export POWERVS_SERVICE_INSTANCE_ID
BASTION_PRIVATE_IP=$(< "${SHARED_DIR}/BASTION_PRIVATE_IP")
export BASTION_PRIVATE_IP
BASTION_PUBLIC_IP=$(< "${SHARED_DIR}/BASTION_PUBLIC_IP")
export BASTION_PUBLIC_IP
KUBECONFIG="${SHARED_DIR}"/kubeconfig
export KUBECONFIG
echo "OCP_VERSION:- ${OCP_VERSION}"
echo "OCP_CLEAN_VERSION:- ${OCP_CLEAN_VERSION}"
echo "CLEAN_VERSION:- ${CLEAN_VERSION}"
echo "NAME_PREFIX:- ${NAME_PREFIX}"
echo "WORKSPACE_NAME:- ${WORKSPACE_NAME}"
echo "VPC_NAME:- ${VPC_NAME}"
echo "POWERVS_SERVICE_INSTANCE_ID:- ${POWERVS_SERVICE_INSTANCE_ID}"
echo "BASTION_PRIVATE_IP:- ${BASTION_PRIVATE_IP}"
echo "BASTION_PUBLIC_IP:- ${BASTION_PUBLIC_IP}"
echo "KUBECONFIG:- ${KUBECONFIG}"

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

OCP_STREAM="ocp"
export OCP_STREAM
# Create a working folder
mkdir -p "${IBMCLOUD_HOME}"/ocp-install-dir

if [ "${ADDITIONAL_WORKERS}" == "0" ]
then
  echo "No additional workers requested"
  exit 0
fi

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

# setup the ibmcloud cli
function setup_ibmcloud_cli() {
  if [ -z "$(command -v ibmcloud)" ]
  then
    echo "ibmcloud CLI doesn't exist, installing"
    curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
  fi

  retry "ibmcloud config --check-version=false"
  retry "ibmcloud version"
}

# setup terraform cli
function setup_terraform_cli() {
  curl -L "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o "${IBMCLOUD_HOME}"/terraform.zip
  cd "${IBMCLOUD_HOME}" || true
  unzip -o "${IBMCLOUD_HOME}"/terraform.zip
  ${IBMCLOUD_HOME}/terraform version
}

# setup the ibmcloud vpc
function cleanup_ibmcloud_vpc() {
  cos_name="${NAME_PREFIX}-multi-arch-intel-cos"

  echo "Cleaning up Instances"
  for INS in $(ibmcloud is instances --output json | jq -r '.[].id')
  do
    VALID_INS=$(ibmcloud is instance "${INS}" --output json | jq -r '. | select(.vpc.name == "'${VPC_NAME}'")')
    if [ -n "${VALID_INS}" ]
    then
      retry "ibmcloud is ind ${INS} --force"
      sleep 60
    fi
  done

  echo "Cleaning up COS Instances"
  VALID_COS=$(ibmcloud resource service-instances 2> /dev/null | grep "${cos_name}" || true)
  if [ -n "${VALID_COS}" ]
  then
    for COS in $(ibmcloud resource service-instance "${cos_name}" --output json -q | jq -r '.[].guid')
    do
      retry "ibmcloud resource service-instance-delete ${COS} --force --recursive"
    done
  fi

  echo "Done cleaning up prior runs"

  echo "Cleanup security group"
  SEC_GROUP_NAME="${VPC_NAME}-workers-sg"

  SEC_GROUP_ID=$(ibmcloud is security-groups --output json | jq -r \
    --arg NAME "$SEC_GROUP_NAME" '.[] | select(.name == $NAME) | .id')

  if [[ -n "$SEC_GROUP_ID" ]]; then
    echo "Deleting security group: $SEC_GROUP_NAME ($SEC_GROUP_ID)"
    ibmcloud is security-group-delete "$SEC_GROUP_ID" -f
  else
    echo "Security group '$SEC_GROUP_NAME' not found."
  fi
  echo "Cleanup security group"
}

# Get node ready count
function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# setup multi-arch vpc workspace
function setup_multi_arch_vpc_workspace(){
  # Before the vpc is created, download the automation code
  cd "${IBMCLOUD_HOME}" || true
  curl -sL "https://github.com/IBM/ocp4-upi-compute-powervs-ibmcloud/archive/refs/heads/release-${OCP_CLEAN_VERSION}.tar.gz" -o ./ocp4-multi-arch-vpc.tar.gz
  tar -xf "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc.tar.gz
  mv ocp4-upi-compute-powervs-ibmcloud-release-"${OCP_CLEAN_VERSION}" ocp4-multi-arch-vpc || true
  cd "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc || true
  ${IBMCLOUD_HOME}/terraform init
}

function create_multi_arch_vpc_tf_varfile(){
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

  cd "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc/ || true
  cp "${PUBLIC_KEY_FILE}" "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc/data/id_rsa.pub
  cp "${PRIVATE_KEY_FILE}" "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc/data/id_rsa
  cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc/data/pull-secret.txt
  echo "Copied the pull secret"

  cat <<EOF >${IBMCLOUD_HOME}/ocp4-multi-arch-vpc/var-multi-arch-vpc.tfvars
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
vpc_skip_ssh_key_create = true
skip_route_creation = true
skip_create_security_group = false
skip_image_creation = true
EOF

  cp "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc/var-multi-arch-vpc.tfvars "${SHARED_DIR}"/var-multi-arch-vpc.tfvars
}

function create_multi_arch_vpc_resources() {
  cd "${IBMCLOUD_HOME}"/ocp4-multi-arch-vpc/ || true
  "${IBMCLOUD_HOME}"/terraform apply -var-file=var-multi-arch-vpc.tfvars -auto-approve -no-color -state="${SHARED_DIR}"/terraform-multi-arch-vpc.tfstate
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
    mkdir -p "${IBMCLOUD_HOME}"
    export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME}"

    setup_ibmcloud_cli
    setup_terraform_cli
    IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IBMCLOUD_API_KEY

    echo "Invoking upi install heterogeneous vpc for ${VPC_NAME}"
    echo "Logging into IBMCLOUD"
    ibmcloud login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
    ibmcloud plugin install -f vpc-infrastructure tg-cli power-iaas

    cleanup_ibmcloud_vpc
    setup_multi_arch_vpc_workspace
    create_multi_arch_vpc_tf_varfile
    create_multi_arch_vpc_resources
  fi
;;
*)
  echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

if [ -f "${SHARED_DIR}"/terraform-multi-arch-vpc.tfstate ]
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