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

PATH=${PATH}:/tmp
export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"

echo "Invoking upi deprovision heterogeneous vpc"
echo "BUILD ID - ${BUILD_ID}"
TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
echo "TRIMMED BUILD ID - ${TRIM_BID}"
OCP_VERSION=$(< "${SHARED_DIR}/OCP_VERSION")
OCP_CLEAN_VERSION=$(echo "${OCP_VERSION}" | awk -F. '{print $1"."$2}')

if [ ! -f "${SHARED_DIR}"/WORKSPACE_NAME ]
then
    echo "short-circuit - workspace name does not exist, nothing to deprovision"
    exit 0
fi

WORKSPACE_NAME=$(<"${SHARED_DIR}"/WORKSPACE_NAME)
export WORKSPACE_NAME
VPC_NAME="${WORKSPACE_NAME}-vpc"
export VPC_NAME

NO_OF_RETRY=${NO_OF_RETRY:-"3"}

# Functions
# Setup ibmcloud cli
function setup_ibmcloud_cli() {
  if [ -z "$(command -v ibmcloud)" ]
  then
    echo "ibmcloud CLI doesn't exist, installing"
    curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
  fi

  mkdir -p "${IBMCLOUD_HOME_FOLDER}"

  ibmcloud config --check-version=false
  ibmcloud version
}

# login to ibm cloud with vpc_region and resource_group
function ibmcloud_login() {
    echo "Logging into IBMCLOUD"
    ibmcloud login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "$(< ${SHARED_DIR}/RESOURCE_GROUP)" -r "$(< ${SHARED_DIR}/VPC_REGION)"
    ibmcloud plugin install -f vpc-infrastructure tg-cli power-iaas
}

function setup_terraform_cli() {
  curl -L "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o "${IBMCLOUD_HOME_FOLDER}"/terraform.zip
  cd "${IBMCLOUD_HOME_FOLDER}" || true
  unzip -o "${IBMCLOUD_HOME_FOLDER}"/terraform.zip
  ${IBMCLOUD_HOME_FOLDER}/terraform version
}

# cleanup the ibmcloud vpc resources
function cleanup_ibmcloud_vpc() {
    CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
    NAME_PREFIX="multi-arch-p-px-${CLEAN_VERSION}"
    cos_name="${NAME_PREFIX}-multi-arch-intel-cos"
    echo "Cleaning up VPC Resources"
    for INS in $(ibmcloud is instances --output json | jq -r '.[].id')
    do
        VALID_INS=$(ibmcloud is instance "${INS}" --output json | jq -r '. | select(.vpc.name == "'${VPC_NAME}'")')
        if [ -n "${VALID_INS}" ]
        then
        ibmcloud is ind ${INS} --force
        sleep 60
        fi
    done
    echo "Cleaning up COS Instances"
    VALID_COS=$(ibmcloud resource service-instances 2> /dev/null | grep "${cos_name}" || true)
    if [ -n "${VALID_COS}" ]
    then
        for COS in $(ibmcloud resource service-instance "${cos_name}" --output json -q | jq -r '.[].guid')
        do
        ibmcloud resource service-instance-delete "${COS}" --force --recursive
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

# Delete the multi-arch VPC resources
function destroy_multi_arch_vpc_resources() {
    if [ -d "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/ ] && [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/terraform.tfstate ] && [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/var-multi-arch-vpc.tfvars ]
    then
        echo "Starting the delete on the multi-arch VPC resources"
        cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc/ || true
        "${IBMCLOUD_HOME_FOLDER}"/terraform destroy -var-file "${SHARED_DIR}"/var-multi-arch-vpc.tfvars -no-color -auto-approve
        rm -rf "${IBMCLOUD_HOME_FOLDER}"/ocp4-multi-arch-vpc
    fi
}

# Main
if [ "${ADDITIONAL_WORKERS}" == "0" ]
then
  echo "No additional workers requested"
  exit 0
fi

echo "Invoking upi deprovision heterogeneous vpc for ${VPC_NAME}"
setup_ibmcloud_cli
setup_terraform_cli
setup_multi_arch_vpc_workspace
clone_multi_arch_vpc_artifacts
ibmcloud_login
destroy_multi_arch_vpc_resources
cleanup_ibmcloud_vpc
echo "IBM Cloud multi-arch VPC resources destroyed successfully $(date)"

exit 0