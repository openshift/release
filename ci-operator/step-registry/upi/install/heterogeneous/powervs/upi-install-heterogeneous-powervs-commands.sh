#!/bin/bash

set -o nounset

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Development Assumptions:
# - jq, yq, openshift-install are installed

##### Constants
IBMCLOUD_HOME=/tmp/ibmcloud
export IBMCLOUD_HOME

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
export IBMCLOUD_HOME_FOLDER

REGION="${LEASED_RESOURCE}"
export REGION

WORKSPACE_NAME="multi-arch-x-px-${REGION}-1"
export WORKSPACE_NAME

PATH=${PATH}:/tmp:"${IBMCLOUD_HOME}/ocp-install-dir"
export PATH

##### Functions
# setup ibmcloud cli and the necessary plugins
function setup_ibmcloud_cli() {
    if [ -z "$(command -v ibmcloud)" ]
    then
        echo "ibmcloud CLI doesn't exist, installing"
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
    fi

    ibmcloud config --check-version=false
    ibmcloud version

    # Services/Plugins installed are for PowerVS, Transit Gateway, VPC, CIS
    ibmcloud plugin install -f power-iaas tg-cli vpc-infrastructure cis
}

# login to the ibmcloud
function login_ibmcloud() {
    echo "IC: Logging into the cloud"
    ibmcloud login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${REGION}"
}

# Download automation code
function download_automation_code() {
    mkdir -p ${IBMCLOUD_HOME_FOLDER}
    echo "Downloading the head for ocp4-upi-compute-powervs"
    cd "${IBMCLOUD_HOME_FOLDER}" \
        && curl -L https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/release-"${OCP_VERSION}"-per.tar.gz -o "${IBMCLOUD_HOME_FOLDER}"/ocp-"${OCP_VERSION}".tar.gz \
        && tar -xzf "${IBMCLOUD_HOME_FOLDER}"/ocp-"${OCP_VERSION}".tar.gz \
        && mv "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs-release-${OCP_VERSION}-per" "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs
    echo "Down ... Downloading the head for ocp4-upi-compute-powervs"
}

# Downloads the terraform binary and puts into the path
function download_terraform_binary() {
    mkdir -p ${IBMCLOUD_HOME_FOLDER}
    echo "Attempting to install terraform using gzip"
    curl -L -o "${IBMCLOUD_HOME}"/ocp-install-dir/terraform.gz -L https://releases.hashicorp.com/terraform/"${TERRAFORM_VERSION}"/terraform_"${TERRAFORM_VERSION}"_linux_amd64.zip \
        && gunzip "${IBMCLOUD_HOME}"/ocp-install-dir/terraform.gz \
        && chmod +x "${IBMCLOUD_HOME}"/ocp-install-dir/terraform
    echo "Terraform installed. expect to see version"
    terraform version -no-color
}

# Cleans up the failed prior jobs
function cleanup_prior() {
    echo "Clean up transit gateway - VPC connection"
    RESOURCE_GROUP_ID=$(ibmcloud resource groups --output json | jq -r '.[] | select(.name == "'${RESOURCE_GROUP}'").id')
    for GW in $(ibmcloud tg gateways --output json | jq --arg resource_group "${RESOURCE_GROUP}" --arg workspace_name "${WORKSPACE_NAME}-tg" -r '.[] | select(.resource_group.id == $resource_group) | select(.name == $workspace_name) | "(.id)"')
    do
        VPC_CONN="${WORKSPACE_NAME}-vpc"
        VPC_CONN_ID="$(ibmcloud tg connections "${GW}" 2>&1 | grep "${VPC_CONN}" | awk '{print $3}')"
        if [ ! -z "${VPC_CONN_ID}" ]
        then
            echo "deleting VPC connection"
            ibmcloud tg connection-delete "${GW}" "${CS}" --force || true
            sleep 120
            echo "Done Cleaning up GW VPC Connection"
        else
            echo "GW VPC Connection not found. VPC Cleanup not needed."
        fi
        break
    done

    # Delete any vpc older than 24 hrs
    echo "Cleaning up VPCs"
    for VPC in $(ibmcloud is vpcs --resource-group-name "${RESOURCE_GROUP}" 2>&1 | grep "${RESOURCE_GROUP}" | grep -v Listing | grep -i ci-op | awk '{print $1}')
    do
        echo "VPC=${VPC}"
        ibmcloud is vpc-delete "${VPC}" -f
        sleep 10s
    done

    echo "Cleaning up workspaces for ${WORKSPACE_NAME}"
    for CRN in $(ibmcloud pi workspace ls 2> /dev/null | grep "${WORKSPACE_NAME}" | awk '{print $1}' || true)
    do
        echo "Targetting power cloud instance"
        ibmcloud pi workspace target "${CRN}"

        echo "Deleting the PVM Instances"
        for INSTANCE_ID in $(ibmcloud pi instance ls --json | jq -r '.pvmInstances[] | .id')
        do
            echo "Deleting PVM Instance ${INSTANCE_ID}"
            ibmcloud pi instance delete "${INSTANCE_ID}" --delete-data-volumes
            sleep 60
        done

        echo "Deleting the Images"
        for IMAGE_ID in $(ibmcloud pi image ls --json | jq -r '.images[].imageID')
        do
            echo "Deleting Images ${IMAGE_ID}"
            ibmcloud pi image delete "${IMAGE_ID}"
            sleep 60
        done

        if [ -n "$(ibmcloud pi network ls 2> /dev/null | grep DHCP || true)" ]
        then
            curl -L -o /tmp/pvsadm "https://github.com/ppc64le-cloud/pvsadm/releases/download/v0.1.12/pvsadm-linux-amd64"
            chmod +x /tmp/pvsadm
            POWERVS_SERVICE_INSTANCE_ID=$(echo "${CRN}" | sed 's|:| |g' | awk '{print $NF}')
            NET_ID=$(IC_API_KEY="@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" /tmp/pvsadm dhcpserver list --instance-id ${POWERVS_SERVICE_INSTANCE_ID} --skip_headers --one_output | awk '{print $2}' | grep -v ID | grep -v '|' | sed '/^$/d' || true)
            IC_API_KEY="@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" /tmp/pvsadm dhcpserver delete --instance-id ${POWERVS_SERVICE_INSTANCE_ID} --id "${NET_ID}" || true
            sleep 60
        fi

        echo "Deleting the Network"
        for NETWORK_ID in $(ibmcloud pi network ls 2> /dev/null | awk '{print $1}')
        do
        echo "Deleting network ${NETWORK_ID}"
        ibmcloud pi network delete "${NETWORK_ID}" || true
        sleep 60
        done
    done

  echo "Done cleaning up prior runs"
}

# configure the automation
function configure_automation() {
    # Saving the OCP VERSION so we can use in a subsequent deprovision
    echo "${OCP_VERSION}" > "${SHARED_DIR}"/OCP_VERSION

    export INSTALL_CONFIG_FILE=${SHARED_DIR}/install-config.yaml
    # Resource Group:
    RESOURCE_GROUP=$(yq -r '.platform.ibmcloud.resourceGroupName' "${SHARED_DIR}/install-config.yaml")
    echo "${RESOURCE_GROUP}" > "${SHARED_DIR}"/RESOURCE_GROUP

    # create workspace for powervs from cli
    echo "Display all the variable values:"
    POWERVS_REGION=$(bash "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/scripts/region.sh "${REGION}")
    echo "VPC Region is ${REGION}"
    echo "PowerVS region is ${POWERVS_REGION}"
    echo "Resource Group is ${RESOURCE_GROUP}"

    # Use existing pvs workspace.
    # Process the CRN into a variable
    CRN=$(cat /tmp/instance.id | grep crn | awk '{print $NF}')
      export CRN
      echo "${CRN}" > "${SHARED_DIR}"/POWERVS_SERVICE_CRN
    # This CRN is useful when manually destroying.
    echo "PowerVS Service CRN: ${CRN}"

    # Set the values to be used for generating var.tfvars
    POWERVS_SERVICE_INSTANCE_ID=$(echo "${CRN}" | sed 's|:| |g' | awk '{print $NF}')
    export POWERVS_SERVICE_INSTANCE_ID

    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY

    export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-privatekey
    export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-publickey
    
    export KUBECONFIG=${SHARED_DIR}/kubeconfig

    # Invoke create-var-file.sh to generate var.tfvars file
    echo "Creating the var file"
    cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs \
        && bash scripts/create-var-file.sh /tmp/ibmcloud "${ADDITIONAL_WORKERS}" "${CUCUSHIFT_TAG}${CLEAN_VERSION}"
    cp "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/data/var.tfvars "${SHARED_DIR}"/var.tfvars

    #Create the VPC to fixed transit gateway Connection for the TG
    for GW in $(ibmcloud tg gateways --output json | jq --arg resource_group "${RESOURCE_GROUP_ID}" --arg workspace_name "${WORKSPACE_NAME}" -r '.[] | select(.resource_group.id == $resource_group) | select(.name == $workspace_name) | "(.id)"')
    do
        for CS in $(ibmcloud is vpcs --output json | jq -r '.[] | select(.name | contains("${WORKSPACE_NAME}-vpc")) | .id')
        do
            VPC_CONN_NAME=$(ibmcloud is vpc "${CS}" --output json | jq -r .name)
            VPC_NW_ID=$(ibmcloud is vpc "${CS}" --output json | jq -r .crn)
            echo "Creating new VPC connection for gateway now."
            ibmcloud tg cc "${GW}" --name "${VPC_CONN_NAME}" --network-id "${VPC_NW_ID}" --network-type vpc || true
        done
    done
}

# The CentOS-Stream-9 image is stock-image on PowerVS.
# This image is available across all PowerVS workspaces.
# The VMs created using this image are used in support of ignition on PowerVS.
function setup_powervs_image() {
    echo "PowerVS Target CRN is: ${CRN}"
    ibmcloud pi workspace target "${CRN}"

    COUNT=$(ibmcloud pi image ls --json | jq -r '.images[] | [.name? | select(. = "CentOS-Stream-9")] | length')
    if [ ${COUNT} -ne 1 ]
    then
        echo "Creating the Centos Stream Image"
        ibmcloud pi image ls
        ibmcloud pi image create CentOS-Stream-9 --json
        echo "Import image status is: $?"
    fi
}

# run_automation executes the terraform based on automation
function run_automation() {
    cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/ \
        && "${IBMCLOUD_HOME_FOLDER}"/terraform init -upgrade -no-color \
        && "${IBMCLOUD_HOME_FOLDER}"/terraform plan -var-file=data/var.tfvars -no-color \
        && "${IBMCLOUD_HOME_FOLDER}"/terraform apply -var-file=data/var.tfvars -auto-approve -no-color \
        || cp -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/terraform.tfstate "${SHARED_DIR}"/terraform.tfstate

    echo "Shared Directory: copy the terraform.tfstate"
    cp -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/terraform.tfstate "${SHARED_DIR}"/terraform.tfstate
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
function wait_for_additional_nodes_readiness() {
    local expected_nodes=${1}
    local MAX_RETRIES=10

    echo "Wait for the nodes to become ready..."
    for i in $(seq 1 "${MAX_RETRIES}") max
    do
        echo "Node details:"
        oc get nodes -lnode-role.kubernetes.io/worker= -Lkubernetes.io/arch --no-headers
        echo ""

        COUNT_NODES=$(oc get nodes -lnode-role.kubernetes.io/worker= -Lkubernetes.io/arch --no-headers | grep -c Ready)
        if [ "${i}" == "max" ]
        then
            echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${COUNT_NODES}... Failing."
            return 1
        fi

        if [ "${COUNT_NODES}" == "${expected_nodes}" ]
        then
            echo "[INFO] Found ${COUNT_NODES}/${expected_nodes} ready nodes, continuing..."
            return 0
        fi

        echo "[INFO] - ${expected_nodes} ready nodes expected, found ${COUNT_NODES}..." \
            "Waiting 3min before retrying..."
        sleep "3m"
    done
}

## Main Execution Path
if [ "${ADDITIONAL_WORKERS}" == "0" ]
then
    echo "No additional workers requested"
    exit 0
fi

if [ "${CLUSTER_TYPE}" != "ibmcloud-multi-ppc64le" ]
then
    echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
    exit 4
fi

if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" != "ppc64le" ]
then
    echo "only runs with ppc64le"
    exit 64
fi

setup_ibmcloud_cli
login_ibmcloud
download_terraform_binary
download_automation_code
configure_automation
cleanup_prior
setup_powervs_image
run_automation
wait_for_additional_nodes_readiness ${ADDITIONAL_WORKERS}

exit 0