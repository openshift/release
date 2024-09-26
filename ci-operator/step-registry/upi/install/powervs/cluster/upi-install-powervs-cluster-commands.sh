#!/bin/bash

set -o nounset

error_handler() {
  echo "Error: (${1}) occurred on (${2})"
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
export POWERVS_REGION
export POWERVS_ZONE
export VPC_REGION
export VPC_ZONE

OCP_STREAM="ocp"
export OCP_STREAM
# Create a working folder
mkdir -p "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir

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


function create_upi_tf_varfile(){
  local workspace_name="${1}"

  export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-privatekey
  export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-publickey
  export CLUSTER_DOMAIN="${BASE_DOMAIN}"
  export IBMCLOUD_CIS_CRN="${IBMCLOUD_CIS_CRN}"
  COREOS_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.ppc64le.artifacts.powervs.formats."ova.gz".disk.location')
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
  IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
  export IBMCLOUD_API_KEY
  # OCP_TMP_VERSION=$(openshift-install version | grep openshift-install | awk '{print $2}')
  # echo "OCP_TMP_VERSION: ${OCP_TMP_VERSION}"

  cat <<EOF >${IBMCLOUD_HOME_FOLDER}/ocp-install-dir/var-multi-arch-upi.tfvars
ibmcloud_region     = "${POWERVS_REGION}"
ibmcloud_api_key    = "${IBMCLOUD_API_KEY}"
ibmcloud_zone       = "${POWERVS_ZONE}"
service_instance_id = "${POWERVS_SERVICE_INSTANCE_ID}"
rhel_image_name     = "CentOS-Stream-9"
rhcos_import_image              = true
rhcos_import_image_filename     = "${COREOS_NAME}"
rhcos_import_image_storage_type = "tier1"
system_type         = "s922"
cluster_domain      = "${CLUSTER_DOMAIN}"
cluster_id_prefix   = "multi-arch-p2"
bastion   = { memory = "16", processors = "1", "count" = 1 }
bootstrap = { memory = "16", processors = "0.5", "count" = 1 }
master    = { memory = "16", processors = "0.5", "count" = 3 }
worker    = { memory = "16", processors = "0.5", "count" = 2 }
openshift_install_tarball = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/latest/ppc64le/openshift-install-linux.tar.gz"
openshift_client_tarball  = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/latest/ppc64le/openshift-client-linux.tar.gz"
# release_image_override    = "quay.io/openshift-release-dev/ocp-release:${OCP_VERSION}-multi"
release_image_override    = "$(openshift-install version | grep 'release image' | awk '{print $3}')"
use_zone_info_for_names   = true
use_ibm_cloud_services    = true
ibm_cloud_vpc_name         = "${workspace_name}-vpc"
ibm_cloud_vpc_subnet_name  = "sn01"
ibm_cloud_resource_group   = "${RESOURCE_GROUP}"
iaas_vpc_region            = "${VPC_REGION}"
ibm_cloud_cis_crn = "${IBMCLOUD_CIS_CRN}"
ibm_cloud_tgw              = "${workspace_name}-tg"
EOF

  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars "${SHARED_DIR}"/var-multi-arch-upi.tfvars
  echo "UPI TFVARS created: ${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars
}

function create_upi_powervs_cluster() {
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/ || true
  # Dev Note: https://github.com/ocp-power-automation/openshift-install-power/blob/devel/openshift-install-powervs#L767C1-L767C145
  # May trigger the redaction
  OUTPUT="yes"
  cd "${IBMCLOUD_HOME_FOLDER}" \
    && curl -L https://github.com/ocp-power-automation/ocp4-upi-powervs/archive/refs/heads/main.tar.gz -o "${IBMCLOUD_HOME_FOLDER}"/ocp.tar.gz \
    && tar -xzf "${IBMCLOUD_HOME_FOLDER}"/ocp.tar.gz \
    && mv "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-powervs-main" "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs
  # short-circuit to download and install terraform
  echo "Attempting to install terraform using gzip"
  curl -L -o "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/terraform.gz -L https://releases.hashicorp.com/terraform/"${TERRAFORM_VERSION}"/terraform_"${TERRAFORM_VERSION}"_linux_amd64.zip \
    && gunzip "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/terraform.gz \
    && chmod +x "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/terraform \
    && export PATH="${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/:"${PATH}" \
    || true

  cd "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/ || true
  cp "${PUBLIC_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa.pub
  cp "${PRIVATE_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa
  chmod 0600 "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa
  PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
  echo "${PULL_SECRET}" > "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/pull-secret.txt 
  cat "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars

  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa.pub "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs/data/id_rsa.pub
  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs/data/id_rsa
  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/pull-secret.txt "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs/data/pull-secret.txt
  echo "Applying terraform"
  cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs && "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/terraform init && "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/terraform apply -auto-approve \
    -var-file "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars | \
    sed '/.*client-certificate-data*/d; /.*token*/d; /.*client-key-data*/d; /- name: /d; /Login to the console with user/d' | \
    while read LINE
    do
      if [[ "${LINE}" == *"BEGIN RSA PRIVATE KEY"* ]]
      then
      OUTPUT=""
      fi
      if [ ! -z "${OUTPUT}" ]
      then
          echo "${LINE}"
      fi
      if [[ "${LINE}" == *"END RSA PRIVATE KEY"* ]]
      then
      OUTPUT="yes"
      fi
    done
  echo "POWERVS CLUSTER IS COMPLETE, log is redacted"
  if [ ! -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs/terraform.tfstate ]
  then
     echo "Terraform did not execute, exiting"
     exit 76
   fi
  cp "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs/terraform.tfstate "${SHARED_DIR}"/terraform-multi-arch-upi.tfstate
  "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/terraform output -raw -no-color bastion_private_ip | tr -d '"' > "${SHARED_DIR}"/BASTION_PRIVATE_IP
  "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/terraform output -raw -no-color bastion_public_ip | tr -d '"' > "${SHARED_DIR}"/BASTION_PUBLIC_IP
  cd .. || true

  BASTION_PUBLIC_IP=$(<"${SHARED_DIR}/BASTION_PUBLIC_IP")
  echo "BASTION_PUBLIC_IP:- $BASTION_PUBLIC_IP"
  BASTION_PRIVATE_IP=$(<"${SHARED_DIR}/BASTION_PRIVATE_IP")
  echo "BASTION_PRIVATE_IP:- $BASTION_PRIVATE_IP"

  export BASTION_PUBLIC_IP
  echo "Retrieving the SSH key"
  scp -i "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/id_rsa root@"${BASTION_PUBLIC_IP}":~/openstack-upi/auth/kubeconfig  "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/
  echo "Done with retrieval"
  cp "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/kubeconfig "${SHARED_DIR}"/kubeconfig
  echo "Done copying the kubeconfig"
}

function ic() {
  HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
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
  SERVICE_NAME=power-iaas
  SERVICE_PLAN_NAME=power-virtual-server-group

  ##Create a Workspace on a Power Edge Router enabled PowerVS zone
  # Dev Note: uses a custom loop since we want to redirect errors
  for i in {1..5}
  do
    echo "Attempt: $i/5"
    echo "Creating powervs workspace"
    ic resource service-instance-create "${WORKSPACE_NAME}" "${SERVICE_NAME}" "${SERVICE_PLAN_NAME}" "${POWERVS_ZONE}" -g "${RESOURCE_GROUP}" --allow-cleanup > /tmp/instance.id
    cat /tmp/instance.id
    if [ $? = 0 ]; then
      break
    elif [ "$i" == "5" ]; then
      echo "All retry attempts failed! Please try running the script again after some time"
    else
      sleep 30
    fi
    [ -f /tmp/instance.id ] && cat /tmp/instance.id && break
  done

  ##Get the CRN
  CRN=$(cat /tmp/instance.id | grep crn | awk '{print $NF}')
  export CRN
  echo "${CRN}" > "${SHARED_DIR}"/POWERVS_SERVICE_CRN

  ##Get the ID
  POWERVS_SERVICE_INSTANCE_ID=$(echo "${CRN}" | sed 's|:| |g' | awk '{print $NF}')
  export POWERVS_SERVICE_INSTANCE_ID
  echo "${POWERVS_SERVICE_INSTANCE_ID}" > "${SHARED_DIR}"/POWERVS_SERVICE_INSTANCE_ID

  ##Target the workspace
  echo "Retry workspace target crn: ${CRN}"
  retry "ic pi workspace target ${CRN}"

  ##Check the status it should be active
  WS_COUNTER=0
  WS_STATE=""
  while [ -z "${WS_STATE}" ]
  do
    WS_COUNTER=$((WS_COUNTER+1))
    TEMP_STATE="$(ic pi workspace get "${POWERVS_SERVICE_INSTANCE_ID}" --json 2> /dev/null | jq -r '.status')"
    echo "pvs workspace state: ${TEMP_STATE}"
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

function create_transit_gateway() {
  local workspace_name="${1}"

  TGW_NAME="${workspace_name}"-tg

  ##Create the Transit Gateway
  ic tg gateway-create --name "${TGW_NAME}" --location "${VPC_REGION}" --routing local --resource-group-id "${RESOURCE_GROUP_ID}" --output json | tee /tmp/tgw.id
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
    echo "tg state: ${TEMP_STATE}"
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
    echo "vpc state: ${TEMP_STATE}"
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
    echo "tg connection state: ${TEMP_STATE}"
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
    echo "tg connection state: ${TEMP_STATE}"
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

  # Saving the OCP VERSION so we can use in a subsequent deprovision
  echo "${OCP_VERSION}" > "${SHARED_DIR}"/OCP_VERSION

  setup_ibmcloud_cli

  IBMCLOUD_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
  export IBMCLOUD_API_KEY

  # Generates a workspace name like rdr-multi-arch-upi-4-14-au-syd-n1
  # this keeps the workspace unique
  CLEAN_VERSION=$(echo "${OCP_VERSION}" | sed 's/\([0-9]*\.[0-9]*\).*/\1/' | tr '.' '-')
  WORKSPACE_NAME=rdr-multi-arch-p2-"${CLEAN_VERSION}"-"${POWERVS_ZONE}"
  VPC_NAME="${WORKSPACE_NAME}"-vpc
  echo "${WORKSPACE_NAME}" > "${SHARED_DIR}"/WORKSPACE_NAME

  echo "IC: Installing cluster to upi for ${WORKSPACE_NAME}"

  echo "IC: Logging into the cloud"
  ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
  retry "ic plugin install -f power-iaas tg-cli vpc-infrastructure cis"

  # Run Cleanup
  cleanup_ibmcloud_powervs "${CLEAN_VERSION}" "${WORKSPACE_NAME}" "${VPC_NAME}"

  echo "IC: Resource Group is ${RESOURCE_GROUP}"
  echo "${RESOURCE_GROUP}" > "${SHARED_DIR}"/RESOURCE_GROUP

  create_powervs_workspace "${WORKSPACE_NAME}"
  ic pi subnet create ocp-net --cidr-block 192.168.200.0/24 --net-type private --dns-servers 9.9.9.9 --gateway 192.168.200.1 --ip-range 192.168.200.10-192.168.200.250 --mtu 9000
  create_transit_gateway "${WORKSPACE_NAME}"
  create_vpc "${WORKSPACE_NAME}" "${VPC_NAME}"
  create_upi_tf_varfile "${WORKSPACE_NAME}"
  fix_user_permissions
  create_upi_powervs_cluster
  echo "Created UPI powervs cluster"
;;
*)
  echo "Creating UPI based PowerVS cluster using ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

exit 0
