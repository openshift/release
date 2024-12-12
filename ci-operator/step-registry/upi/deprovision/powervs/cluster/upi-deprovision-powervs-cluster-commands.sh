#!/bin/bash

set -o nounset

# Variables
IBMCLOUD_HOME=/tmp/ibmcloud
export IBMCLOUD_HOME
NO_OF_RETRY=${NO_OF_RETRY:-"5"}
VPC_REGION=$(< "${SHARED_DIR}/VPC_REGION")
export VPC_REGION

# PATH Override
export PATH="${IBMCLOUD_HOME}"/ocp-install-dir/:"${PATH}"

############################################################
# Functions

# Reports the error and where the line it occurs.
function error_handler() {
  echo "Error: (${1}) occurred on (${2})"
}

# setup home folder
function setup_home() {
    mkdir -p "${IBMCLOUD_HOME}"/ocp-install-dir
}

# Retry an input a set number of times
function retry {
  cmd=$1
  for retry in $(seq 1 "${NO_OF_RETRY}")
  do
    echo "Attempt: $retry/${NO_OF_RETRY}"
    ret_code=0
    $cmd || ret_code=$?
    if [ $ret_code = 0 ]
    then
      break
    elif [ "$retry" == "${NO_OF_RETRY}" ]
    then
      error_handler "All retry attempts failed! Please try running the script again after some time" $ret_code
    else
      sleep 30
    fi
  done
}

# Report on builds and save the OCP VERSION
function report_build(){
    echo "Invoking installation of UPI based PowerVS cluster"
    echo "BUILD ID - ${BUILD_ID}"
    TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
    echo "TRIMMED BUILD ID - ${TRIM_BID}"

    # Saving the OCP VERSION so we can use in a subsequent deprovision
    echo "${OCP_VERSION}" > "${SHARED_DIR}"/OCP_VERSION
    echo "OCP_VERSION: ${OCP_VERSION}"
}

# setup ibmcloud cli and the necessary plugins
function setup_ibmcloud_cli() {
    if [ -z "$(command -v ibmcloud)" ]
    then
        echo "ibmcloud CLI doesn't exist, installing"
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
    fi

    retry "ibmcloud config --check-version=false"
    retry "ibmcloud version"

    # Servibmcloudes/Plugins installed are for PowerVS, Transit Gateway, VPC, CIS
    retry "ibmcloud plugin install -f power-iaas tg-cli vpc-infrastructure cis"
}

# login to the ibmcloud
function login_ibmcloud() {
    echo "IC: Logging into the cloud"
    ibmcloud login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
}

# Download automation code
function download_automation_code() {
    echo "Downloading the head for ocp-upi-powervs"
    cd "${IBMCLOUD_HOME}" \
        && curl -L https://github.com/ocp-power-automation/ocp4-upi-powervs/archive/refs/heads/main.tar.gz \
            -o "${IBMCLOUD_HOME}"/ocp.tar.gz \
        && tar -xzf "${IBMCLOUD_HOME}"/ocp.tar.gz \
        && mv "${IBMCLOUD_HOME}/ocp4-upi-powervs-main" "${IBMCLOUD_HOME}"/ocp4-upi-powervs
    echo "Down ... Downloading the head for ocp-upi-powervs"
}

# Downloads the terraform binary and puts into the path
function download_terraform_binary() {
    echo "Attempting to install terraform using gzip"
    curl -L -o "${IBMCLOUD_HOME}"/ocp-install-dir/terraform.gz -L https://releases.hashicorp.com/terraform/"${TERRAFORM_VERSION}"/terraform_"${TERRAFORM_VERSION}"_linux_amd64.zip \
        && gunzip "${IBMCLOUD_HOME}"/ocp-install-dir/terraform.gz \
        && chmod +x "${IBMCLOUD_HOME}"/ocp-install-dir/terraform
    echo "Terraform installed. expect to see version"
    terraform version
}

# Cleanup prior runs
# VPC: Load Balancers, images, vm instances
# PowerVS: images, pvm instances
# Not Covered:
#   COS: bucket, objects
function cleanup_prior() {
    echo "Cleaning up prior runs for lease"
    WORKSPACE_NAME="$(cat ${SHARED_DIR}/WORKSPACE_NAME)"
    VPC_NAME="${WORKSPACE_NAME}-vpc"
    export VPC_NAME

    # PowerVS Instances
    echo "Cleaning up target PowerVS workspace"
    for CRN in $(ibmcloud pi workspace ls 2> /dev/null | grep "${WORKSPACE_NAME}" | awk '{print $1}' || true)
    do
        echo "Targetting power cloud instance"
        ibmcloud pi workspace target "${CRN}"

        echo "Deleting the PVM Instances"
        for INSTANCE_ID in $(ibmcloud pi instance ls --json | jq -r '.pvmInstances[].id')
        do
            echo "Deleting PVM Instance ${INSTANCE_ID}"
            retry "ibmcloud pi instance delete ${INSTANCE_ID} --delete-data-volumes"
            sleep 5
        done
        sleep 60

        echo "Deleting the Images"
        for IMAGE_ID in $(ibmcloud pi image ls --json | jq -r '.images[] | select(.name | contains("CentOS-Stream-9")| not).imageID')
        do
            echo "Deleting Images ${IMAGE_ID}"
            retry "ibmcloud pi image delete ${IMAGE_ID}"
            sleep 5
        done
        sleep 60

        # Dev: functions don't work inline with xargs
        echo "Delete network non-'ocp-net' on PowerVS region"
        ibmcloud pi subnet ls --json | jq -r '[.networks[] | select(.name | contains("ocp-net") | not)] | .[]?.networkID' | xargs --no-run-if-empty -I {} ibmcloud pi subnet delete {} || true
        echo "Done deleting non-'ocp-net' on PowerVS"

        echo "[STATUS:Done] Deleting the contents in ${CRN}"
    done

    # VPC Instances
    # VPC LBs
        # VPC Instances
    # VPC LBs 
    WORKSPACE_NAME="multi-arch-comp-${LEASED_RESOURCE}-1"
    VPC_NAME="${WORKSPACE_NAME}-vpc"

    echo "Target region - ${VPC_REGION}"
    ibmcloud target -r "${VPC_REGION}" -g "${RESOURCE_GROUP}"

    echo "Cleaning up the VPC Load Balancers"
    for SUB in $(ibmcloud is subnets --output json 2>&1 | jq --arg vpc "${VPC_NAME}" -r '.[] | select(.vpc.name | contains($vpc)).id')
    do
        echo "Subnet: ${SUB}"
        # Searches the VSIs and LBs to delete them
        for VSI in $(ibmcloud is subnet "${SUB}" --vpc "${VPC_NAME}" --output json --show-attached | jq -r '.instances[]?.name')
        do
            ibmcloud is instance-delete "${VSI}" --force || true
        done

        echo "Deleting LB in ${SUB}"
        for LB in $(ibmcloud is subnet "${SUB}" --vpc "${VPC_NAME}" --output json --show-attached | jq -r '.load_balancers[].name')
        do
            ibmcloud is load-balancer-delete "${LB}" --force --vpc "${VPC_NAME}" || true
        done
        sleep 120
    done

    echo "Cleaning up the Security Groups"
    ibmcloud is security-groups --vpc "${VPC_NAME}" --resource-group-name "${RESOURCE_GROUP}" --output json \
        | jq -r '[.[] | select(.name | contains("ocp-sec-group"))] | .[]?.name' \
        | xargs --no-run-if-empty -I {} ibmcloud is security-group-delete {} --vpc "${VPC_NAME}" --force\
        || true

    # VPC Images
    # TODO: FIXME add filtering by date.... ?
    for RESOURCE_TGT in $(ibmcloud is images --owner-type user --resource-group-name "${RESOURCE_GROUP}" --output json | jq -r '.[].id')
    do
        ibmcloud is image-delete "${RESOURCE_TGT}" -f
    done

    echo "Done cleaning up prior runs"
}

# Destroy the cluster based on the set configuration / tfvars
function destroy_upi_cluster() {
    echo "destroy terraform to build PowerVS UPI cluster"

    cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/id_rsa
    cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/id_rsa.pub
    chmod 0600 "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/id_rsa

    # Loads the tfvars if it exists in the shared directory
    if [ ! -f "${SHARED_DIR}"/var-multi-arch-upi.tfvars ]
    then
        echo "No tfvars provided. exiting..."
        exit 0
    fi

    cp "${SHARED_DIR}"/var-multi-arch-upi.tfvars "${IBMCLOUD_HOME}"/ocp4-upi-powervs/var-multi-arch-upi.tfvars 
    echo "UPI TFVARS copied: ${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/var-multi-arch-upi.tfvars

    # Loads the tfstate if it exists in the shared directory
    if [ ! -f "${SHARED_DIR}"/terraform.tfstate ]
    then
        echo "No tfstate file provided"
        exit 0
    fi

    cp "${SHARED_DIR}"/terraform.tfstate "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/terraform.tfstate

    # Destroys the current installation for this run
    cd "${IBMCLOUD_HOME}"/ocp4-upi-powervs && \
        "${IBMCLOUD_HOME}"/ocp-install-dir/terraform init && \
        "${IBMCLOUD_HOME}"/ocp-install-dir/terraform destroy -auto-approve \
            -var-file "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/var-multi-arch-upi.tfvars \
            -state "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/terraform.tfstate
}

############################################################
# Execution Path

trap 'error_handler $? $LINENO' ERR

echo "Invoking upi deprovision heterogeneous powervs"

setup_home
setup_ibmcloud_cli
download_terraform_binary
download_automation_code
login_ibmcloud
cleanup_prior
destroy_upi_cluster

echo "IBM Cloud PowerVS resources destroyed successfully $(date)"

exit 0
