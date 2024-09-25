#!/bin/bash

set -o nounset

error_handler() {
  echo "Error: (${1}) occurred on (${2})"
}

trap 'error_handler $? $LINENO' ERR

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
echo "Invoking upi deprovision heterogeneous vpc"
echo "BUILD ID - ${BUILD_ID}"
TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
echo "TRIMMED BUILD ID - ${TRIM_BID}"
OCP_VERSION=$(< "${SHARED_DIR}/OCP_VERSION")
OCP_CLEAN_VERSION=$(echo "${OCP_VERSION}" | awk -F. '{print $1"."$2}')
CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
export NAME_PREFIX="rdr-multi-arch-${CLEAN_VERSION}"
WORKSPACE_NAME=$(<"${SHARED_DIR}"/WORKSPACE_NAME)
export WORKSPACE_NAME
VPC_NAME="${WORKSPACE_NAME}-vpc"
export VPC_NAME
VPC_REGION=$(< "${SHARED_DIR}/VPC_REGION")
echo "VPC_REGION:- ${VPC_REGION}"
export VPC_REGION


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

function setup_ibmcloud_cli() {
  if [ -z "$(command -v ibmcloud)" ]
  then
    echo "ibmcloud CLI doesn't exist, installing"
    curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
  fi

  retry "ic config --check-version=false"
  retry "ic version"
}

function setup_terraform_cli() {
  curl -L "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o "${IBMCLOUD_HOME_FOLDER}"/terraform.zip
  cd "${IBMCLOUD_HOME_FOLDER}" || true
  unzip -o "${IBMCLOUD_HOME_FOLDER}"/terraform.zip
  ${IBMCLOUD_HOME_FOLDER}/terraform version
}

function cleanup_ibmcloud_vpc() {
  cos_name="${NAME_PREFIX}-multi-arch-intel-cos"

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

function setup_multi_arch_vpc_workspace(){
  # Before the vpc is created, download the automation code
  cd "${IBMCLOUD_HOME_FOLDER}" || true
  curl -sL "https://github.com/IBM/ocp4-upi-compute-powervs-ibmcloud/archive/refs/heads/release-${OCP_CLEAN_VERSION}.tar.gz" -o ./ocp4-multi-arch-vpc.tar.gz
  tar -xf "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc.tar.gz
  mv ocp4-upi-compute-powervs-ibmcloud-release-"${OCP_CLEAN_VERSION}" ocp4-multi-arch-vpc || true
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc || true
  ${IBMCLOUD_HOME_FOLDER}/terraform init
}

function clone_multi_arch_vpc_artifacts(){
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

  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/ || true
  cp "${PUBLIC_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/data/id_rsa.pub
  cp "${PRIVATE_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/data/id_rsa

  if [ -f "${SHARED_DIR}"/var-multi-arch-vpc.tfvars ]
  then
    cp "${SHARED_DIR}"/var-multi-arch-vpc.tfvars "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/var-multi-arch-vpc.tfvars
    cat "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/var-multi-arch-vpc.tfvars
  fi

  if [ -f "${SHARED_DIR}"/terraform-multi-arch-vpc.tfstate ]
  then
    cp "${SHARED_DIR}"/terraform-multi-arch-vpc.tfstate "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/terraform.tfstate
  fi
}

function destroy_multi_arch_vpc_resources() {
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/ || true
  "${IBMCLOUD_HOME_FOLDER}"/terraform destroy -var-file var-multi-arch-vpc.tfvars -auto-approve || true
}

echo "Invoking upi deprovision heterogeneous vpc for ${VPC_NAME}"

PATH=${PATH}:/tmp
mkdir -p "${IBMCLOUD_HOME_FOLDER}"
export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"

setup_ibmcloud_cli
setup_terraform_cli
setup_multi_arch_vpc_workspace
clone_multi_arch_vpc_artifacts

echo "Logging into IBMCLOUD"
ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
retry "ic plugin install -f vpc-infrastructure tg-cli power-iaas"

# transit_gateway_routes_report

# Delete the multi-arch VPC resources
if [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/terraform.tfstate ] && [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/var-multi-arch-vpc.tfvars ]
then
  echo "Starting the delete on the multi-arch VPC resources"
  destroy_multi_arch_vpc_resources
  rm -rf "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc
fi

# Delete the workspace created
echo "Starting the delete on the VPC resources"
cleanup_ibmcloud_vpc
echo "IBM Cloud multi-arch VPC resources destroyed successfully $(date)"

exit 0
