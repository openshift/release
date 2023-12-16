#!/bin/bash

set -o nounset
set -x
exit 0
error_handler() {
  echo "Error: ($1) occurred on $2"
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
export NAME_PREFIX="rdr-mac-${CLEAN_VERSION}-${TRIM_BID}"
export CLUSTER_ID_PREFIX="ocp"
export CLUSTER_ID="hetro-ci"
export VPC_REGION="au-syd"
export VPC_NAME="${NAME_PREFIX}-vpc"
echo "VPC_REGION:- ${VPC_REGION}"

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
  for i in $(seq 1 "$NO_OF_RETRY"); do
    echo "Attempt: $i/$NO_OF_RETRY"
    ret_code=0
    $cmd || ret_code=$?
    if [ $ret_code = 0 ]; then
      break
    elif [ "$i" == "$NO_OF_RETRY" ]; then
      error "All retry attempts failed! Please try running the script again after some time" $ret_code
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

  retry "ic config --check-version=false"
  retry "ic version"
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
  vpc_name=${VPC_NAME}
  tgw_name="${VPC_NAME}-tg"
  cos_name="${NAME_PREFIX}-mac-intel-cos"
  cc_name="mac-cloud-conn-${CLUSTER_ID_PREFIX}-${CLUSTER_ID}"
  workspace_name=$(<"${SHARED_DIR}"/WORKSPACE_NAME)

  echo "Cleaning up the Transit Gateways"
  RESOURCE_GROUP_ID=$(ic resource groups --output json | jq -r '.[] | select(.name == "'${RESOURCE_GROUP}'").id')
  for GW in $(ic tg gateways --output json | jq -r '.[].id')
  do
  VALID_GW=$(ic tg gw "${GW}" --output json | jq -r '. | select(.resource_group.id == "'$RESOURCE_GROUP_ID'" and .location == "'${VPC_REGION}'" and .name == "'$tgw_name'")')
  if [ -n "${VALID_GW}" ]
  then
    for CS in $(ic tg connections "${GW}" --output json | jq -r '.[].id')
    do 
      retry "ic tg connection-delete ${GW} ${CS} --force"
    done
    sleep 150
    retry "ic tg gwd ${GW} --force"
    echo "waiting up a minute while the Transit Gateways are removed"
    sleep 90
  fi
  done

  echo "Cleaning up Cloud Connections"
  for CRN in $(ic pi sl 2> /dev/null | grep "${workspace_name}" | awk '{print $1}' || true)
  do
    echo "Targetting power cloud instance"
    retry "ic pi st ${CRN}"
    for CC in $(ic pi cons --json | jq -r '.[][] | select(.name == "'${cc_name}'").cloudConnectionID')
    do
      echo "Deleting Cloud Connection ${CC}"
      retry "ic pi cond ${CC}"
      sleep 90
    done
  done

  echo "Cleaning up Instances"
  for INS in $(ic is instances --output json | jq -r '.[].id')
  do
    VALID_INS=$(ic is instance "${INS}" --output json | jq -r '. | select(.vpc.name == "'${vpc_name}'")')
    if [ -n "${VALID_INS}" ]
    then
      retry "ic is ind ${INS} --force"
      sleep 60
    fi
  done

  echo "Cleaning up Subnets"
  for SUB in $(ic is subnets --output json | jq -r '.[].id')
  do
    VALID_SUB=$(ic is subnet "${SUB}" --output json | jq -r '. | select(.vpc.name == "'${vpc_name}'")')
    if [ -n "${VALID_SUB}" ]
    then
      # VALID_LB=$(ic is subnet "${SUB}" --show-attached --output json | jq -r '.' | grep "load_balancers")
      # if [ -n "${VALID_LB}" ]
      # then
      #   for LB in $(ic is subnet "${SUB}" --show-attached --output json | jq -r '.load_balancers[].id')
      #   do
      #     LBSTATUS=$(ic is lb "${LB}" --output json | jq -r '.provisioning_status')
      #     if [ "${LBSTATUS}" == "active" ]
      #     then
      #       retry "ic is lbd ${LB} --force"
      #       sleep 30
      #     else
      #       echo "Load Balancer with ID: ${LB} not in active state, cannot be deleted."
      #     fi
      #   done
      # fi
      # sleep 300
      retry "ic is subnetd ${SUB} --force"
      sleep 60
    fi
  done

  echo "Cleaning up Public Gateways"
  for PGW in $(ic is pubgws --output json | jq -r '.[].id')
  do
    VALID_PGW=$(ic is pubgw "${PGW}" --output json | jq -r '. | select(.vpc.name == "'${vpc_name}'")')
    if [ -n "${VALID_PGW}" ]
    then
      retry "ic is pubgwd ${PGW} --force"
      sleep 60
    fi
  done

  echo "Cleaning up VPC"
  VALID_VPC=$(ic is vpc "${vpc_name}" --output json 2> /dev/null | jq -r '.id')
  if [ -n "${VALID_VPC}" ]
  then
    retry "ic is vpcd ${VALID_VPC} --force"
    sleep 60
  fi

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

function setup_mac_vpc_workspace(){
  # Before the vpc is created, download the automation code
  cd "${IBMCLOUD_HOME_FOLDER}" || true
  curl -sL "https://github.com/IBM/ocp4-upi-compute-powervs-ibmcloud/archive/refs/heads/release-${OCP_CLEAN_VERSION}.tar.gz" -o ./ocp4-mac-vpc.tar.gz
  tar -xf "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc.tar.gz
  mv ocp4-upi-compute-powervs-ibmcloud-release-"${OCP_CLEAN_VERSION}" ocp4-mac-vpc || true
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc || true
  ${IBMCLOUD_HOME_FOLDER}/terraform init
}

function clone_mac_vpc_artifacts(){
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

  if [ -f "${SHARED_DIR}"/var-mac-vpc.tfvars ]
  then
    cp "${SHARED_DIR}"/var-mac-vpc.tfvars "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/var-mac-vpc.tfvars
    cat "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/var-mac-vpc.tfvars
  fi

  if [ -f "${SHARED_DIR}"/terraform-mac-vpc.tfstate ]
  then
    cp "${SHARED_DIR}"/terraform-mac-vpc.tfstate "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/terraform.tfstate
  fi
}

function destroy_mac_vpc_resources() {
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/ || true
  "${IBMCLOUD_HOME_FOLDER}"/terraform destroy -var-file var-mac-vpc.tfvars -auto-approve || true
}

function transit_gateway_routes_report() {
  tgwrr_name="${VPC_NAME}-tg"
  echo "Routes Report of Transit Gateway"
  RESOURCE_GROUP_ID=$(ic resource groups --output json | jq -r '.[] | select(.name == "'${RESOURCE_GROUP}'").id')
  for GW in $(ic tg gateways --output json | jq -r '.[].id')
  do
    VALID_GW=$(ic tg gw "${GW}" --output json | jq -r '. | select(.resource_group.id == "'$RESOURCE_GROUP_ID'" and .location == "'${VPC_REGION}'" and .name == "'$tgwrr_name'")')
    if [ -n "${VALID_GW}" ]
    then
      retry "ic tg rrc ${GW}"
      sleep 60
      retry "ic tg rrs ${GW}"
    fi
  done
}

echo "Invoking upi deprovision heterogeneous vpc for ${VPC_NAME}"

PATH=${PATH}:/tmp
mkdir -p "${IBMCLOUD_HOME_FOLDER}"
export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"

setup_jq
setup_ibmcloud_cli
setup_terraform_cli
setup_mac_vpc_workspace
clone_mac_vpc_artifacts

echo "Logging into IBMCLOUD"
ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
retry "ic plugin install -f vpc-infrastructure tg-cli power-iaas"

transit_gateway_routes_report

# Delete the MAC VPC resources
if [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/terraform.tfstate ] && [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc/var-mac-vpc.tfvars ]
then
  echo "Starting the delete on the MAC VPC resources"
  destroy_mac_vpc_resources
  rm -rf "${IBMCLOUD_HOME_FOLDER}"/ocp4-mac-vpc
fi

# Delete the workspace created
echo "Starting the delete on the VPC resources"
cleanup_ibmcloud_vpc
echo "IBM Cloud MAC VPC resources destroyed successfully $(date)"

exit 0
