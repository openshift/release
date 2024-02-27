#!/bin/bash

set -o nounset
set -x

error_handler() {
  echo "Error: ($1) occurred on $2"
}

trap 'error_handler $? $LINENO' ERR

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
echo "Invoking installation of UPI based PowerVS cluster"
echo "BUILD ID - ${BUILD_ID}"
TRIM_BID=$(echo "${BUILD_ID}" | cut -c 1-6)
echo "TRIMMED BUILD ID - ${TRIM_BID}"

POWERVS_ZONE="${LEASED_RESOURCE}"
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
VPC_ZONE="${VPC_REGION}-1"

echo "${POWERVS_REGION}" > "${SHARED_DIR}"/POWERVS_REGION
echo "${POWERVS_ZONE}" > "${SHARED_DIR}"/POWERVS_ZONE
echo "${VPC_REGION}" > "${SHARED_DIR}"/VPC_REGION
echo "${VPC_ZONE}" > "${SHARED_DIR}"/VPC_ZONE
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
      error_handler "All retry attempts failed! Please try running the script again after some time" $ret_code
    else
      sleep 30
    fi
  done
}

function setup_upi_workspace(){
  # Before the workspace is created, download the automation code
  mkdir -p "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir || true
  curl -sL https://raw.githubusercontent.com/ocp-power-automation/openshift-install-power/"${UPI_AUTOMATION_VERSION}"/openshift-install-powervs -o ./openshift-install-powervs
  chmod +x ./openshift-install-powervs
  ./openshift-install-powervs setup
}

function create_upi_tf_varfile(){
  local workspace_name="${1}"

  export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-privatekey
  export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-publickey
  export CLUSTER_DOMAIN="${BASE_DOMAIN}"
  export IBMCLOUD_CIS_CRN="${IBMCLOUD_CIS_CRN}"
  COREOS_URL=$(/tmp/openshift-install coreos print-stream-json | jq -r '.architectures.ppc64le.artifacts.powervs.formats."ova.gz".disk.location')
  COREOS_FILE=$(echo "${COREOS_URL}" | sed 's|/| |g' | awk '{print $NF}')
  COREOS_NAME=$(echo "${COREOS_FILE}" | tr '.' '-' | sed 's|-0-powervs-ppc64le-ova-gz|-0-ppc64le-powervs.ova.gz|g')

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
  chmod 0600 "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa
  PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
  echo "${PULL_SECRET}" > "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/pull-secret.txt

  cat <<EOF >${IBMCLOUD_HOME_FOLDER}/ocp-install-dir/var-mac-upi.tfvars
ibmcloud_region     = "${POWERVS_REGION}"
ibmcloud_zone       = "${POWERVS_ZONE}"
service_instance_id = "${POWERVS_SERVICE_INSTANCE_ID}"
rhel_image_name     = "CentOS-Stream-8"
rhcos_import_image              = true
rhcos_import_image_filename     = "${COREOS_NAME}"
rhcos_import_image_storage_type = "tier1"
system_type         = "e980"
cluster_domain      = "${CLUSTER_DOMAIN}"
cluster_id_prefix   = "rh-ci"
bastion   = { memory = "16", processors = "1", "count" = 1 }
bootstrap = { memory = "16", processors = "0.5", "count" = 1 }
master    = { memory = "16", processors = "0.5", "count" = 3 }
worker    = { memory = "16", processors = "0.5", "count" = 2 }
openshift_install_tarball = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/${OCP_VERSION}/ppc64le/openshift-install-linux.tar.gz"
openshift_client_tarball  = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/${OCP_VERSION}/ppc64le/openshift-client-linux.tar.gz"
release_image_override    = "quay.io/openshift-release-dev/ocp-release:${OCP_VERSION}-multi"
use_zone_info_for_names   = true
use_ibm_cloud_services    = true
ibm_cloud_vpc_name         = "${workspace_name}-vpc"
ibm_cloud_vpc_subnet_name  = "sn01"
ibm_cloud_resource_group   = "${RESOURCE_GROUP}"
iaas_vpc_region            = "${VPC_REGION}"
ibm_cloud_cis_crn = "${IBMCLOUD_CIS_CRN}"
ibm_cloud_tgw              = "${workspace_name}-tg"
EOF

  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-mac-upi.tfvars "${SHARED_DIR}"/var-mac-upi.tfvars
  cat "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-mac-upi.tfvars
}

function create_upi_powervs_cluster() {
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/ || true
  ./openshift-install-powervs create -var-file var-mac-upi.tfvars -verbose || true
  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/automation/terraform.tfstate "${SHARED_DIR}"/terraform-mac-upi.tfstate
  ./openshift-install-powervs output > "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/mac-upi-output
  ./openshift-install-powervs access-info > "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/mac-upi-access-info
  cat "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/mac-upi-output
  cat "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/mac-upi-access-info
  ./openshift-install-powervs output bastion_private_ip | tr -d '"' > "${SHARED_DIR}"/BASTION_PRIVATE_IP
  ./openshift-install-powervs output bastion_public_ip | tr -d '"' > "${SHARED_DIR}"/BASTION_PUBLIC_IP

  BASTION_PUBLIC_IP=$(<"${SHARED_DIR}/BASTION_PUBLIC_IP")
  echo "BASTION_PUBLIC_IP:- $BASTION_PUBLIC_IP"
  BASTION_PRIVATE_IP=$(<"${SHARED_DIR}/BASTION_PRIVATE_IP")
  echo "BASTION_PRIVATE_IP:- $BASTION_PRIVATE_IP"

  export BASTION_PUBLIC_IP
  scp -v -i "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa root@"${BASTION_PUBLIC_IP}":~/openstack-upi/auth/kubeconfig  "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/
  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/kubeconfig "${SHARED_DIR}"/kubeconfig
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

function setup_openshift_installer() {
  OCP_STREAM="ocp"
  ocp_target_version="candidate-4.15"
  echo "proceed to re-installing openshift-install"
  curl -L "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/${ocp_target_version}/amd64/openshift-install-linux.tar.gz" -o "${IBMCLOUD_HOME_FOLDER}"/openshift-install.tar.gz
  tar -xf "${IBMCLOUD_HOME_FOLDER}"/openshift-install.tar.gz -C "${IBMCLOUD_HOME_FOLDER}"
  cp "${IBMCLOUD_HOME_FOLDER}"/openshift-install /tmp/
  OCP_VERSION="$(/tmp/openshift-install version | head -n 1 | awk '{print $2}')"
  export OCP_VERSION
  export OCP_STREAM
}

function fix_user_permissions() {
  if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
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
    for INSTANCE_ID in $(ic pi instance ls --json | jq -r '.pvmInstances[].id')
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
    sleep 30
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

  echo "Cleaning up the Subnets"
  for SUB in $(ic is subnets --output json | jq -r '.[].id')
  do
    VALID_SUB=$(ic is subnet "${SUB}" --output json | jq -r '. | select(.vpc.name | contains("'${VPC_NAME}'"))')
    if [ -n "${VALID_SUB}" ]
    then
      retry "ic is subnetd ${SUB} --force"
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
      sleep 60
    fi
  done

  echo "Delete the VPC Instance"
  VALID_VPC=$(ic is vpcs 2> /dev/null | grep "${vpc_name}" || true)
  if [ -n "${VALID_VPC}" ]
  then
    retry "ic is vpc-delete ${vpc_name} --force"
    echo "waiting up a minute while the vpc is deleted"
    sleep 60
  fi

  echo "Done cleaning up prior runs"
}

function create_powervs_workspace() {
  local workspace_name="${1}"

  ##List the resource group id
  RESOURCE_GROUP_ID=$(ic resource group "${RESOURCE_GROUP}" --id)
  export RESOURCE_GROUP_ID
  echo "${RESOURCE_GROUP_ID}" > "${SHARED_DIR}"/RESOURCE_GROUP_ID

  ##Create a Workspace on a Power Edge Router enabled PowerVS zone
  retry "ic pi workspace create ${workspace_name} --datacenter ${POWERVS_ZONE} --group ${RESOURCE_GROUP_ID} --plan public"
  sleep 60
  ic pi workspace list 2>&1 | grep "${workspace_name}" | tee /tmp/instance.id

  ##Get the CRN
  CRN=$(cat /tmp/instance.id | grep crn | awk '{print $1}')
  export CRN
  echo "${CRN}" > "${SHARED_DIR}"/POWERVS_SERVICE_CRN

  ##Get the ID
  POWERVS_SERVICE_INSTANCE_ID=$(cat /tmp/instance.id | grep crn | awk '{print $2}')
  export POWERVS_SERVICE_INSTANCE_ID
  echo "${POWERVS_SERVICE_INSTANCE_ID}" > "${SHARED_DIR}"/POWERVS_SERVICE_INSTANCE_ID

  ##Target the workspace
  retry "ic pi workspace target ${CRN}"

  ##Check the status it should be active
  WS_COUNTER=0
  WS_STATE=""
  while [ -z "${WS_STATE}" ]
  do
  WS_COUNTER=$((WS_COUNTER+1)) 
  TEMP_STATE="$(ic pi workspace get "${POWERVS_SERVICE_INSTANCE_ID}" --json 2> /dev/null | jq -r '.status')"
  echo "Current State is: ${TEMP_STATE}"
  echo ""
  if [ "${TEMP_STATE}" == "active" ]
  then
    WS_STATE="active"
  elif [[ $WS_COUNTER -ge 20 ]]
  then
    WS_STATE="pending"
    echo "Workspace has not come up in active state... login and verify"
    exit 2
  else
    echo "Waiting for Workspace to become active... [30 seconds]"
    sleep 30
  fi
  done
}

function create_powervs_private_network() {
  local CRN="${1}"

  echo "Creating the Network"
  echo "PowerVS Target CRN is: ${CRN}"
  retry "ic pi workspace target ${CRN}"

  ##Create a Power Network using the CRN
  retry "ic pi subnet create ocp-net --cidr-block 192.168.200.0/24 --net-type private --dns-servers 9.9.9.9 --gateway 192.168.200.1 --ip-range 192.168.200.10-192.168.200.250  --jumbo"
}

function import_centos_image() {
  local CRN="${1}"

  # The CentOS-Stream-8 image is stock-image on PowerVS.
  # This image is available across all PowerVS workspaces.
  # The VMs created using this image are used in support of ignition on PowerVS.
  echo "Creating the Centos Stream Image"
  echo "PowerVS Target CRN is: ${CRN}"
  retry "ic pi workspace target ${CRN}"
  retry "ic pi image list"

  ##Import the Centos8 image
  retry "ic pi image create CentOS-Stream-8 --json"
  echo "Import image status is: $?"
}

function create_transit_gateway() {
  local workspace_name="${1}"

  TGW_NAME="${workspace_name}"-tg

  ##Create the Transit Gateway
  ic tg gateway-create --name "${TGW_NAME}" --location "${VPC_REGION}" --routing global --resource-group-id "${RESOURCE_GROUP_ID}" --output json | tee /tmp/tgw.id
  TGW_ID=$(cat /tmp/tgw.id | grep id | awk -F'"' '/"id":/{print $4; exit}')
  export TGW_ID
  echo "${TGW_ID}" > "${SHARED_DIR}"/TGW_ID

  ##Check the status it should be available
  TGW_COUNTER=0
  TGW_STATE=""
  while [ -z "${TGW_STATE}" ]
  do
  TGW_COUNTER=$((TGW_COUNTER+1)) 
  TEMP_STATE="$(ic tg gw "${TGW_ID}" --output json 2> /dev/null | jq -r '.status')"
  echo "Current State is: ${TEMP_STATE}"
  echo ""
  if [ "${TEMP_STATE}" == "available" ]
  then
    TGW_STATE="available"
  elif [[ $TGW_COUNTER -ge 20 ]]
  then
    TGW_STATE="pending"
    echo "Transit Gateway has not come up in available state... login and verify"
    exit 2
  else
    echo "Waiting for Transit Gateway to become available... [30 seconds]"
    sleep 30
  fi
  done
}

function create_vpc() {
  local workspace_name="${1}"
  local vpc_name="${2}"

  ##Create a VPC with at least one subnet with a Public Gateway
  retry "ic is vpc-create ${vpc_name} --resource-group-id ${RESOURCE_GROUP_ID} --output JSON"

  ##Check the status it should be available
  VPC_COUNTER=0
  VPC_STATE=""
  while [ -z "${VPC_STATE}" ]
  do
  VPC_COUNTER=$((VPC_COUNTER+1)) 
  TEMP_STATE="$(ic is vpc "${vpc_name}" --output json 2> /dev/null | jq -r '.status')"
  echo "Current State is: ${TEMP_STATE}"
  echo ""
  if [ "${TEMP_STATE}" == "available" ]
  then
    VPC_STATE="available"
  elif [[ $VPC_COUNTER -ge 20 ]]
  then
    VPC_STATE="pending"
    echo "VPC has not come up in available state... login and verify"
    exit 2
  else
    echo "Waiting for VPC to become available... [30 seconds]"
    sleep 30
  fi
  done

  ##Fetch VPC CRN
  VPC_CRN="$(ic is vpc "${vpc_name}" --output json 2> /dev/null | jq -r '.crn')"
  export VPC_CRN
  echo "${VPC_CRN}" > "${SHARED_DIR}"/VPC_CRN

  ##Add a subnet
  retry "ic is subnet-create sn01 ${vpc_name} --resource-group-id ${RESOURCE_GROUP_ID} --ipv4-address-count 256 --zone ${VPC_ZONE}"

  ##Attach a public gateway to the subnet
  retry "ic is public-gateway-create gw01 ${vpc_name} ${VPC_ZONE} --resource-group-id ${RESOURCE_GROUP_ID} --output JSON"

  ##Attach the Public Gateway to the Subnet
  retry "ic is subnet-update sn01 --vpc ${vpc_name} --pgw gw01"

  ##Attach the PER network to the TG
  ic tg connection-create "${TGW_ID}" --name powervs-conn --network-id "${CRN}" --network-type power_virtual_server --output json | tee /tmp/tgwper.id
  TGW_PER_ID=$(cat /tmp/tgwper.id | grep id | awk -F'"' '/"id":/{print $4; exit}')
  export TGW_PER_ID
  echo "${TGW_PER_ID}" > "${SHARED_DIR}"/TGW_PER_ID

  ##Check the status it should be attached
  TGW_PER_COUNTER=0
  TGW_PER_STATE=""
  while [ -z "${TGW_PER_STATE}" ]
  do
  TGW_PER_COUNTER=$((TGW_PER_COUNTER+1)) 
  TEMP_STATE="$(ic tg connection "${TGW_ID}" "${TGW_PER_ID}" --output json 2> /dev/null | jq -r '.status')"
  echo "Current State is: ${TEMP_STATE}"
  echo ""
  if [ "${TEMP_STATE}" == "attached" ]
  then
    TGW_PER_STATE="attached"
  elif [[ $TGW_PER_COUNTER -ge 20 ]]
  then
    TGW_PER_STATE="pending"
    echo "PER has not attached to Transit Gateway... login and verify"
    exit 2
  else
    echo "Waiting for PER to attached to Transit Gateway... [30 seconds]"
    sleep 30
  fi
  done

  ##Attach the VPC to the TG
  ic tg connection-create "${TGW_ID}" --name vpc-conn --network-id "${VPC_CRN}" --network-type vpc --output json | tee /tmp/tgwvpc.id
  TGW_VPC_ID=$(cat /tmp/tgwvpc.id | grep id | awk -F'"' '/"id":/{print $4; exit}')
  export TGW_VPC_ID
  echo "${TGW_VPC_ID}" > "${SHARED_DIR}"/TGW_VPC_ID

  ##Check the status it should be attached
  TGW_VPC_COUNTER=0
  TGW_VPC_STATE=""
  while [ -z "${TGW_VPC_STATE}" ]
  do
  TGW_VPC_COUNTER=$((TGW_VPC_COUNTER+1)) 
  TEMP_STATE="$(ic tg connection "${TGW_ID}" "${TGW_VPC_ID}" --output json 2> /dev/null | jq -r '.status')"
  echo "Current State is: ${TEMP_STATE}"
  echo ""
  if [ "${TEMP_STATE}" == "attached" ]
  then
    TGW_VPC_STATE="attached"
  elif [[ $TGW_VPC_COUNTER -ge 20 ]]
  then
    TGW_VPC_STATE="pending"
    echo "VPC has not attached to Transit Gateway... login and verify"
    exit 2
  else
    echo "Waiting for VPC to attached to Transit Gateway... [30 seconds]"
    sleep 30
  fi
  done
}

echo "Cluster type is ${CLUSTER_TYPE}"

case "$CLUSTER_TYPE" in
*powervs*)
  PATH=${PATH}:/tmp
  mkdir -p "${IBMCLOUD_HOME_FOLDER}"
  export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"

  setup_openshift_installer
  # Saving the OCP VERSION so we can use in a subsequent deprovision
  echo "${OCP_VERSION}" > "${SHARED_DIR}"/OCP_VERSION

  setup_jq
  setup_ibmcloud_cli

  IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
  export IBMCLOUD_API_KEY

  # Generates a workspace name like rdr-mac-upi-4-14-au-syd-n1
  # this keeps the workspace unique
  CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
  WORKSPACE_NAME=rdr-mac-p2-"${CLEAN_VERSION}"-"${POWERVS_ZONE}"
  VPC_NAME="${WORKSPACE_NAME}"-vpc
  echo "${WORKSPACE_NAME}" > "${SHARED_DIR}"/WORKSPACE_NAME

  echo "Invoking upi install heterogeneous powervs for ${WORKSPACE_NAME}"

  echo "Logging into IBMCLOUD"
  ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
  retry "ic plugin install -f power-iaas tg-cli vpc-infrastructure cis"

  # Run Cleanup
  cleanup_ibmcloud_powervs "${CLEAN_VERSION}" "${WORKSPACE_NAME}" "${VPC_NAME}"

  echo "Resource Group is ${RESOURCE_GROUP}"
  echo "${RESOURCE_GROUP}" > "${SHARED_DIR}"/RESOURCE_GROUP

  create_powervs_workspace "${WORKSPACE_NAME}"
  create_powervs_private_network "${CRN}"
  import_centos_image "${CRN}"
  create_transit_gateway "${WORKSPACE_NAME}"
  create_vpc "${WORKSPACE_NAME}" "${VPC_NAME}"
  setup_upi_workspace
  create_upi_tf_varfile "${WORKSPACE_NAME}"
  fix_user_permissions
  create_upi_powervs_cluster
;;
*)
  echo "Creating UPI based PowerVS cluster using ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

exit 0
