#!/bin/bash

set -o nounset

error_handler() {
  echo "Error: (${1}) occurred on (${2})"
}

trap 'error_handler $? $LINENO' ERR

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
echo "Invoking upi deprovision powervs cluster"
echo "BUILD ID - ${BUILD_ID}"
TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
echo "TRIMMED BUILD ID - ${TRIM_BID}"


OCP_VERSION=$(< "${SHARED_DIR}/OCP_VERSION")
CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
WORKSPACE_NAME=$(< "${SHARED_DIR}/WORKSPACE_NAME")
VPC_NAME="${WORKSPACE_NAME}"-vpc
if [ ! -f "${SHARED_DIR}/RESOURCE_GROUP" ]
then
  echo "RESOURCE_GROUP is not set, exiting cleanly"
  exit 0
fi
RESOURCE_GROUP=$(< "${SHARED_DIR}/RESOURCE_GROUP")
VPC_REGION=$(< "${SHARED_DIR}/VPC_REGION")
echo "VPC_REGION:- ${VPC_REGION}"
export VPC_REGION

NO_OF_RETRY=${NO_OF_RETRY:-"5"}

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

function ic() {
  HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
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

function setup_upi_workspace(){
  # Before the workspace is deleted, download the automation code
  mkdir -p "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir || true
  curl -sL https://raw.githubusercontent.com/ocp-power-automation/openshift-install-power/"${UPI_AUTOMATION_VERSION}"/openshift-install-powervs -o ./openshift-install-powervs
  chmod +x ./openshift-install-powervs
  ./openshift-install-powervs setup -ignore-os-checks
}

function clone_upi_artifacts(){
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

  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/ || true
  cp "${PUBLIC_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa.pub
  cp "${PRIVATE_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa
  PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
  echo "${PULL_SECRET}" > "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/pull-secret.txt

  if [ -f "${SHARED_DIR}"/var-multi-arch-upi.tfvars ]
  then
    cp "${SHARED_DIR}"/var-multi-arch-upi.tfvars "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars
    cat "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars
  fi

  if [ -f "${SHARED_DIR}"/terraform-multi-arch-upi.tfstate ]
  then
    cp "${SHARED_DIR}"/terraform-multi-arch-upi.tfstate "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/automation/terraform.tfstate
  fi
}

function destroy_upi_powervs_cluster() {
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/ || true
  ./openshift-install-powervs destroy -ignore-os-checks -var-file var-multi-arch-upi.tfvars -force-destroy || true
}

function cleanup_ibmcloud_powervs() {
  local version="${1}"
  local workspace_name="${2}"
  local vpc_name="${3}"

  echo "Cleaning up the Transit Gateways"
  for GW in $(ic tg gateways --output json | jq -r '.[].id')
  do
    echo "Checking the resource_group and location for the transit gateways ${GW}"
    VALID_GW=$(ic tg gw "${GW}" --output json | jq -r '. | select(.name | contains("'${WORKSPACE_NAME}'"))')
    if [ -n "${VALID_GW}" ]
    then
      for CS in $(ic tg connections "${GW}" --output json | jq -r '.[].id')
      do 
        retry "ic tg connection-delete ${GW} ${CS} --force"
        sleep 30
      done
      retry "ic tg gwd ${GW} --force"
      echo "waiting up a minute while the Transit Gateways are removed"
      sleep 60
    fi
  done

  echo "Cleaning up prior runs - version: ${version} - workspace_name: ${workspace_name}"

  echo "Cleaning up workspaces for ${workspace_name}"
  for CRN in $(ic pi workspace ls 2> /dev/null | grep "${workspace_name}" | awk '{print $1}' || true)
  do
    echo "Targetting power cloud instance"
    retry "ic pi workspace target ${CRN}"

    echo "Deleting the PVM Instances"
    for INSTANCE_ID in $(ic pi instance ls --json | jq -r '.pvmInstances[] | .id')
    do
      echo "Deleting PVM Instance ${INSTANCE_ID}"
      retry "ic pi instance delete ${INSTANCE_ID} --delete-data-volumes"
      sleep 60
    done

    echo "Deleting the Images"
    for IMAGE_ID in $(ic pi image ls --json | jq -r '.images[].imageID')
    do
      echo "Deleting Images ${IMAGE_ID}"
      retry "ic pi image delete ${IMAGE_ID}"
      sleep 60
    done

    echo "Deleting the Network"
    for NETWORK_ID in $(ic pi subnet ls --json | jq -r '.networks[].networkID')
    do
      echo "Deleting network ${NETWORK_ID}"
      retry "ic pi subnet delete ${NETWORK_ID}"
      sleep 60
    done

    retry "ic resource service-instance-update ${CRN} --allow-cleanup true"
    sleep 60
    retry "ic resource service-instance-delete ${CRN} --force --recursive"
    for COUNT in $(seq 0 5)
    do
      FIND=$(ic pi workspace ls 2> /dev/null | grep "${CRN}" || true)
      echo "FIND: ${FIND}"
      if [ -z "${FIND}" ]
      then
        echo "service-instance is deprovisioned"
        break
      fi
      echo "waiting on service instance to deprovision ${COUNT}"
      sleep 60
    done
    echo "Done Deleting the ${CRN}"
  done

  echo "Cleaning up the VPC Instances"
  for RESOURCE_TGT in $(ic is subnets --output json | jq -r '.[].id')
  do
    VALID_SUB=$(ic is subnet "${RESOURCE_TGT}" --output json | jq -r '. | select(.vpc.name | contains("'${VPC_NAME}'"))')
    if [ -n "${VALID_SUB}" ]
    then
        # Searches the VSIs and LBs to delete them
        for VSI in $(ic is subnet "${SUB}" --vpc "${VPC_NAME}" --output json --show-attached | jq -r '.instances[].name')
        do
            ic is instance-delete "${VSI}" --force || true
        done

        for LB in $(ic is subnet "${SUB}" --vpc "${VPC_NAME}" --output json --show-attached | jq -r '.load_balancers[].name')
        do
            ic is load-balancer-delete "${LB}" --force --vpc "${VPC_NAME}" || true
        done
        sleep 60
    fi
  done

  echo "Cleaning up the Subnets"
  for SUB in $(ic is subnets --output json | jq -r '.[].id')
  do
    VALID_SUB=$(ic is subnet "${SUB}" --output json | jq -r '. | select(.vpc.name | contains("'${VPC_NAME}'"))')
    if [ -n "${VALID_SUB}" ]
    then
      # Load Balancers might be still attached from PowerVS UPI cluster setup.
      ic is subnetd "${SUB}" --force || true
      echo "waiting up a minute while the Subnets are removed"
      sleep 60
    fi
  done

  echo "Cleaning up the Public Gateways"
  for PGW in $(ic is pubgws --output json | jq -r '.[].id')
  do
    VALID_PGW=$(ic is pubgw "${PGW}" --output json | jq -r '. | select(.vpc.name | contains("'${VPC_NAME}'"))')
    if [ -n "${VALID_PGW}" ]
    then
      retry "ic is pubgwd ${PGW} --force"
      echo "waiting up a minute while the Public Gateways are removed"
    fi
  done

  echo "Delete the VPC Instance"
  VALID_VPC=$(ic is vpcs 2> /dev/null | grep "${vpc_name}" || true)
  if [ -n "${VALID_VPC}" ]
  then
    retry "ic is vpc-delete ${vpc_name} --force"
    echo "waiting up a minute while the vpc is deleted"
  fi

  echo "Done cleaning up prior runs"
}

echo "Invoking upi deprovision heterogeneous powervs for ${WORKSPACE_NAME}"

PATH=${PATH}:/tmp
mkdir -p "${IBMCLOUD_HOME_FOLDER}"
export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"

setup_ibmcloud_cli

IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
export IBMCLOUD_API_KEY

setup_upi_workspace
clone_upi_artifacts

echo "Logging into IBMCLOUD"
ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
retry "ic plugin install -f power-iaas tg-cli vpc-infrastructure cis"

# Delete the UPI PowerVS cluster created
if [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/automation/terraform.tfstate ] && [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars ]
then
  echo "Starting the delete on the UPI PowerVS cluster resources"
  destroy_upi_powervs_cluster
  rm -rf "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir
fi

# Delete the workspace created
if [ -f "${SHARED_DIR}/POWERVS_SERVICE_CRN" ]
then
  echo "Starting the delete on the PowerVS resources"
  cleanup_ibmcloud_powervs "${CLEAN_VERSION}" "${WORKSPACE_NAME}" "${VPC_NAME}"
fi

echo "IBM Cloud PowerVS resources destroyed successfully $(date)"

exit 0
