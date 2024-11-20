#!/bin/bash

set -o nounset

############################################################
# Variables
IBMCLOUD_HOME=/tmp/ibmcloud
export IBMCLOUD_HOME
NO_OF_RETRY=${NO_OF_RETRY:-"5"}

############################################################
# Set PowerVS and VPC Zone and Region  
export POWERVS_ZONE="${LEASED_RESOURCE}"
POWERVS_REGION=$(
        case "$POWERVS_ZONE" in
            ("dal10" | "dal12") echo "dal" ;;
            ("us-south") echo "us-south" ;;
            ("wdc06" | "wdc07") echo "wdc" ;;
            ("us-east") echo "us-east" ;;
            ("sao01" | "sao04") echo "sao" ;;
            ("tor01") echo "tor" ;;
            ("mon01") echo "mon" ;;
            ("eu-de-1" | "eu-de-2") echo "eu-de" ;;
            ("lon04" | "lon06") echo "lon" ;;
            ("mad02" | "mad04") echo "mad" ;;
            ("syd04" | "syd05") echo "syd" ;;
            ("tok04") echo "tok" ;;
            ("osa21") echo "osa" ;;
            (*) echo "$POWERVS_ZONE" ;;
        esac)
export POWERVS_REGION
VPC_REGION=$(
        case "$POWERVS_ZONE" in
            ("dal10" | "dal12" | "us-south") echo "us-south" ;;
            ("wdc06" | "wdc07" | "us-east") echo "us-east" ;;
            ("sao01" | "sao04") echo "br-sao" ;;
            ("tor01") echo "ca-tor" ;;
            ("mon01") echo "ca-mon" ;;
            ("eu-de-1" | "eu-de-2") echo "eu-de" ;;
            ("lon04" | "lon06") echo "eu-gb" ;;
            ("mad02" | "mad04") echo "eu-es" ;;
            ("syd04" | "syd05") echo "au-syd" ;;
            ("tok04") echo "jp-tok" ;;
            ("osa21") echo "jp-osa" ;;
            (*) echo "$POWERVS_ZONE" ;;
        esac)
export VPC_REGION
export VPC_ZONE="${VPC_REGION}-1"

echo "Variables for Workflow are being stored in SHARED_DIR."
echo "${POWERVS_REGION}" > "${SHARED_DIR}"/POWERVS_REGION
echo "${POWERVS_ZONE}" > "${SHARED_DIR}"/POWERVS_ZONE
echo "${VPC_REGION}" > "${SHARED_DIR}"/VPC_REGION
echo "${VPC_ZONE}" > "${SHARED_DIR}"/VPC_ZONE

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

    # Services/Plugins installed are for PowerVS, Transit Gateway, VPC, CIS
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
    terraform version -no-color
}

# facilitates scp copy from inside the contianer
function fix_user_permissions() {
    # Dev Note: scp in a container needs this fix-up
    if ! whoami &> /dev/null
    then
        if [[ -w /etc/passwd ]]
        then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
        fi
    fi
}

# Cleanup prior runs
# VPC: Load Balancers, images, vm instances
# PowerVS: images, pvm instances
# Not Covered:
#   COS: bucket, objects
function cleanup_prior() {
    echo "Cleaning up prior runs for lease"
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
        echo "Done Deleting the ${CRN}"
    done

    # Dev: functions don't work inline with xargs
    echo "Delete network non-'ocp-net' on PowerVS region"
    ibmcloud pi subnet ls --json | jq -r '[.networks[] | select(.name | contains("ocp-net") | not)] | .[]?.networkID' | xargs --no-run-if-empty -I {} ibmcloud pi subnet delete {} || true
    echo "Done deleting non-'ocp-net' on PowerVS"

    # VPC Instances
    # VPC LBs 
    WORKSPACE_NAME="multi-arch-comp-${LEASED_RESOURCE}-1"
    VPC_NAME="${WORKSPACE_NAME}-vpc"
    echo "Target region - ${VPC_REGION}"
    ibmcloud target -r "${VPC_REGION}" -g "${RESOURCE_GROUP}"

    echo "Cleaning up the Security Groups"
    ibmcloud is security-groups --vpc "${VPC_NAME}" --resource-group-name "${RESOURCE_GROUP}" --output json \
        | jq -r '[.[] | select(.name | contains("ocp-sec-group"))] | .[]?.name' \
        | xargs --no-run-if-empty -I {} ibmcloud is security-group-delete {} --vpc "${VPC_NAME}" --force\
        || true

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
        sleep 60
    done

    # VPC Images
    # TODO: FIXME add filtering by date.... ?
    for RESOURCE_TGT in $(ibmcloud is images --owner-type user --resource-group-name "${RESOURCE_GROUP}" --output json | jq -r '.[].id')
    do
        ibmcloud is image-delete "${RESOURCE_TGT}" -f
    done

    echo "Done cleaning up prior runs"
}

# creates the var file
function configure_terraform() {

    OCP_STREAM="ocp"
    export OCP_STREAM

    IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"

    echo "IC: Resource Group is ${RESOURCE_GROUP}"
    echo "${RESOURCE_GROUP}" > "${SHARED_DIR}"/RESOURCE_GROUP

    echo "IC: Setup the keys"
    cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/id_rsa
    cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/id_rsa.pub
    chmod 0600 "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/id_rsa

    echo "IC: domain and cis update"
    CLUSTER_DOMAIN="${BASE_DOMAIN}"
    IBMCLOUD_CIS_CRN="${IBMCLOUD_CIS_CRN}"

    echo "IC: coreos"
    COREOS_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.ppc64le.artifacts.powervs.formats."ova.gz".disk.location')
    COREOS_FILE=$(echo "${COREOS_URL}" | sed 's|/| |g' | awk '{print $NF}')
    COREOS_NAME=$(echo "${COREOS_FILE}" | tr '.' '-' | sed 's|-0-powervs-ppc64le-ova-gz|-0-ppc64le-powervs.ova.gz|g' )

    PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
    echo "${PULL_SECRET}" > "${IBMCLOUD_HOME}"/ocp4-upi-powervs/data/pull-secret.txt

    WORKSPACE_NAME="multi-arch-comp-${LEASED_RESOURCE}-1"
    VPC_NAME="${WORKSPACE_NAME}-vpc"
    echo "IC workspace :  ${WORKSPACE_NAME}"
    echo "IC VPC workspace :  ${VPC_NAME}"
    echo "${WORKSPACE_NAME}" > "${SHARED_DIR}"/WORKSPACE_NAME

    # Select the workspace ID 
    POWERVS_SERVICE_INSTANCE_ID=$(ibmcloud pi workspace ls --json | jq --arg wn "${WORKSPACE_NAME}" -r '.Payload.workspaces[] | select(.name | contains($wn)).id')
    echo "IC: PowerVS instance ID: ${POWERVS_SERVICE_INSTANCE_ID}"
    export POWERVS_SERVICE_INSTANCE_ID

    echo "Release Image used is:"
    curl -o /tmp/versions.json -s 'https://multi.ocp.releases.ci.openshift.org/graph?arch=ppc64le'
    jq -r --arg nightly nightly --arg version ${OCP_VERSION} '[.nodes[] | select(.version | (contains($nightly) and startswith($version)))][0].payload' /tmp/versions.json > /tmp/target_version
    TARGET_VERSION="$(< /tmp/target_version)"
    export TARGET_VERSION
    echo "${TARGET_VERSION}"

cat << EOF >${IBMCLOUD_HOME}/ocp-install-dir/var-multi-arch-upi.tfvars
ibmcloud_api_key    = "${IBMCLOUD_API_KEY}"
ibmcloud_zone       = "${POWERVS_ZONE}"
ibmcloud_region     = "${POWERVS_REGION}"
service_instance_id = "${POWERVS_SERVICE_INSTANCE_ID}"
rhel_image_name     = "CentOS-Stream-9"
rhcos_image_name                = "${COREOS_NAME}"
rhcos_import_image              = true
rhcos_import_image_filename     = "${COREOS_NAME}"
rhcos_import_image_storage_type = "tier5k"
system_type         = "s922"
cluster_domain      = "${CLUSTER_DOMAIN}"
cluster_id_prefix   = "p2"
bastion   = { memory = "16", processors = "1", "count" = 1 }
bootstrap = { memory = "16", processors = "1", "count" = 1 }
master    = { memory = "16", processors = "1", "count" = 3 }
worker    = { memory = "16", processors = "1", "count" = 2 }
openshift_install_tarball = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/latest/ppc64le/openshift-install-linux.tar.gz"
openshift_client_tarball  = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/latest/ppc64le/openshift-client-linux.tar.gz"
release_image_override    = "${TARGET_VERSION}"

use_zone_info_for_names   = true
use_ibm_cloud_services    = true
ibm_cloud_vpc_name        = "${VPC_NAME}"
private_network_mtu       = 9000
ibm_cloud_vpc_subnet_name  = "sn01"
ibm_cloud_resource_group   = "${RESOURCE_GROUP}"
iaas_vpc_region            = "${VPC_REGION}"
ibm_cloud_cis_crn = "${IBMCLOUD_CIS_CRN}"
ibm_cloud_tgw              = "${WORKSPACE_NAME}-tg"
EOF

    cp "${IBMCLOUD_HOME}"/ocp-install-dir/var-multi-arch-upi.tfvars "${SHARED_DIR}"/var-multi-arch-upi.tfvars
    echo "UPI TFVARS created: ${IBMCLOUD_HOME}"/ocp-install-dir/var-multi-arch-upi.tfvars
}

# Builds the cluster based on the set configuration / tfvars
function build_upi_cluster() {
    OUTPUT="yes"
    echo "Applying terraform to build PowerVS UPI cluster"
    cd "${IBMCLOUD_HOME}"/ocp4-upi-powervs && \
        "${IBMCLOUD_HOME}"/ocp-install-dir/terraform init -no-color && \
        "${IBMCLOUD_HOME}"/ocp-install-dir/terraform apply -auto-approve -no-color \
            -var-file "${IBMCLOUD_HOME}"/ocp-install-dir/var-multi-arch-upi.tfvars \
            -state "${IBMCLOUD_HOME}"/ocp4-upi-powervs/terraform.tfstate \
            | sed '/.client-certificate-data/d; /.token/d; /.client-key-data/d; /- name: /d; /Login to the console with user/d' | \
                while read LINE
                do
                    if [[ "${LINE}" == "BEGIN RSA PRIVATE KEY" ]]
                    then
                    OUTPUT=""
                    fi
                    if [ ! -z "${OUTPUT}" ]
                    then
                        echo "${LINE}"
                    fi
                    if [[ "${LINE}" == "END RSA PRIVATE KEY" ]]
                    then
                    OUTPUT="yes"
                    fi
                done

    if [ ! -f "${IBMCLOUD_HOME}"/ocp4-upi-powervs/terraform.tfstate ]
    then
        echo "Terraform did not execute, exiting"
        exit 76
    fi

    echo "Extracting the terraformm output from the state file"
    "${IBMCLOUD_HOME}"/ocp-install-dir/terraform output -raw -no-color bastion_private_ip \
            -state="${IBMCLOUD_HOME}"/ocp4-upi-powervs/terraform.tfstate | \
        tr -d '"' > "${SHARED_DIR}"/BASTION_PRIVATE_IP
    "${IBMCLOUD_HOME}"/ocp-install-dir/terraform output -raw -no-color bastion_public_ip \
            -state="${IBMCLOUD_HOME}"/ocp4-upi-powervs/terraform.tfstate | \
        tr -d '"' > "${SHARED_DIR}"/BASTION_PUBLIC_IP

    # public ip not shared for security reasons
    BASTION_PUBLIC_IP=$(<"${SHARED_DIR}/BASTION_PUBLIC_IP")
    BASTION_PRIVATE_IP=$(<"${SHARED_DIR}/BASTION_PRIVATE_IP")
    echo "BASTION_PRIVATE_IP:- $BASTION_PRIVATE_IP"

    if [ -z "${BASTION_PUBLIC_IP}" ]
    then
        echo "Unexpected it's blank"
        exit 77
    fi

    echo "Retrieving the SSH key"
    scp -i "${IBMCLOUD_HOME}"/ocp-install-dir/id_rsa root@"${BASTION_PUBLIC_IP}":~/openstack-upi/auth/kubeconfig  "${IBMCLOUD_HOME}"/ocp-install-dir/
    echo "Done with retrieval"
    cp "${IBMCLOUD_HOME}"/ocp-install-dir/kubeconfig "${SHARED_DIR}"/kubeconfig

    echo "Copying the terraform.tfstate"
    cp "${IBMCLOUD_HOME}"/ocp4-upi-powervs/terraform.tfstate "${SHARED_DIR}"/terraform.tfstate
    echo "Done copying the kubeconfig"
}

############################################################
# Execution Path

trap 'error_handler $? $LINENO' ERR


report_build
setup_home
setup_ibmcloud_cli
download_terraform_binary
download_automation_code
login_ibmcloud
configure_terraform
cleanup_prior
fix_user_permissions
build_upi_cluster

echo "Successfully created the PowerVS cluster"
exit 0