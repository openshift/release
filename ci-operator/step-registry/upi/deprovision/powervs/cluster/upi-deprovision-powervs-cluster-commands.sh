#!/bin/bash

set -o nounset
set -x

error_handler() {
  echo "Error: ($1) occurred on $2"
}

trap 'error_handler $? $LINENO' ERR
exit 0

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
echo "Invoking upi deprovision powervs cluster"
echo "BUILD ID - ${BUILD_ID}"
TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
echo "TRIMMED BUILD ID - ${TRIM_BID}"

if [ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

OCP_VERSION=$(< "${SHARED_DIR}/OCP_VERSION")
CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
WORKSPACE_NAME=$(< "${SHARED_DIR}/WORKSPACE_NAME")
RESOURCE_GROUP=$(< "${SHARED_DIR}/RESOURCE_GROUP")

NO_OF_RETRY=${NO_OF_RETRY:-"5"}

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

function ic() {
  HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
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

function setup_upi_workspace(){
  # Before the workspace is deleted, download the automation code
  mkdir -p "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir || true
  curl -sL https://raw.githubusercontent.com/ocp-power-automation/openshift-install-power/"${UPI_AUTOMATION_VERSION}"/openshift-install-powervs -o ./openshift-install-powervs
  chmod +x ./openshift-install-powervs
  ./openshift-install-powervs setup
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

  if [ -f "${SHARED_DIR}"/var-mac-upi.tfvars ]
  then
    cp "${SHARED_DIR}"/var-mac-upi.tfvars "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-mac-upi.tfvars
    cat "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-mac-upi.tfvars
  fi

  if [ -f "${SHARED_DIR}"/terraform-mac-upi.tfstate ]
  then
    cp "${SHARED_DIR}"/terraform-mac-upi.tfstate "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/automation/terraform.tfstate
  fi
}

function destroy_upi_powervs_cluster() {
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/ || true
  ./openshift-install-powervs destroy -var-file var-mac-upi.tfvars -force-destroy || true
}

function cleanup_ibmcloud_powervs() {
  local version="${1}"
  local workspace_name="${2}"

  echo "Cleaning up - version: ${version} - workspace_name: ${workspace_name}"

  echo "Cleaning up workspaces for ${workspace_name}"
  for CRN in $(ic pi sl 2> /dev/null | grep "${workspace_name}" | awk '{print $1}' || true)
  do
    echo "Targetting power cloud instance"
    retry "ic pi st ${CRN}"

    echo "Deleting the PVM Instances"
    for INSTANCE_ID in $(ic pi ins --json | jq -r '.pvmInstances[].pvmInstanceID')
    do
      echo "Deleting PVM Instance ${INSTANCE_ID}"
      retry "ic pi ind ${INSTANCE_ID} --delete-data-volumes"
      sleep 60
    done

    echo "Deleting the Images"
    for IMAGE_ID in $(ic pi imgs --json | jq -r '.images[].imageID')
    do
      echo "Deleting Images ${IMAGE_ID}"
      retry "ic pi image-delete ${IMAGE_ID}"
      sleep 60
    done

    echo "Deleting the Network"
    for NETWORK_ID in $(ic pi nets --json | jq -r '.networks[].networkID')
    do
      echo "Deleting network ${NETWORK_ID}"
      retry "ic pi network-delete ${NETWORK_ID}"
      sleep 60
    done

    retry "ic resource service-instance-update ${CRN} --allow-cleanup true"
    sleep 30
    retry "ic resource service-instance-delete ${CRN} --force --recursive"
    for COUNT in $(seq 0 5)
    do
      FIND=$(ic pi sl 2> /dev/null| grep "${CRN}" || true)
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

  echo "Done cleaning up prior runs"
}

echo "Invoking upi deprovision heterogeneous powervs for ${WORKSPACE_NAME}"

PATH=${PATH}:/tmp
mkdir -p "${IBMCLOUD_HOME_FOLDER}"
export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"

setup_jq
setup_ibmcloud_cli

IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
export IBMCLOUD_API_KEY

setup_upi_workspace
clone_upi_artifacts

echo "Logging into IBMCLOUD"
ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" --no-region
retry "ic plugin install -f power-iaas"

# Delete the UPI PowerVS cluster created
if [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/automation/terraform.tfstate ] && [ -f "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-mac-upi.tfvars ]
then
  echo "Starting the delete on the UPI PowerVS cluster resources"
  destroy_upi_powervs_cluster
  rm -rf "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir
fi

# Delete the workspace created
if [ -f "${SHARED_DIR}/POWERVS_SERVICE_CRN" ]
then
  echo "Starting the delete on the PowerVS resources"
  cleanup_ibmcloud_powervs "${CLEAN_VERSION}" "${WORKSPACE_NAME}"
fi

echo "IBM Cloud PowerVS resources destroyed successfully $(date)"

exit 0
