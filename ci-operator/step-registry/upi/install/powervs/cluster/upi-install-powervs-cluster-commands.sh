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
  POWERVS_SERVICE_INSTANCE_ID="626e36c2-6a2e-4ce2-91e1-543185709880"
  export POWERVS_SERVICE_INSTANCE_ID

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
bootstrap = { memory = "16", processors = "1", "count" = 1 }
master    = { memory = "16", processors = "1", "count" = 3 }
worker    = { memory = "16", processors = "1", "count" = 2 }
openshift_install_tarball = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/latest/ppc64le/openshift-install-linux.tar.gz"
openshift_client_tarball  = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/${OCP_STREAM}/latest/ppc64le/openshift-client-linux.tar.gz"
# release_image_override    = "quay.io/openshift-release-dev/ocp-release:${OCP_VERSION}-multi"
release_image_override    = "$(openshift-install version | grep 'release image' | awk '{print $3}')"
use_zone_info_for_names   = true
use_ibm_cloud_services    = true
ibm_cloud_vpc_name        = "${workspace_name}"
private_network_mtu       = 9000
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
    -var-file "${IBMCLOUD_HOME_FOLDER}"/ocp-install-dir/var-multi-arch-upi.tfvars -state "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-powervs/terraform.tfstate | \
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
  sleep 7200
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
    echo "Done Deleting the ${CRN}"
  done
  echo "Done cleaning up prior runs"
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
  WORKSPACE_NAME=rdr-multi-arch-p2-1
  VPC_NAME="${WORKSPACE_NAME}"
  echo "${WORKSPACE_NAME}" > "${SHARED_DIR}"/WORKSPACE_NAME

  echo "IC: Installing cluster to upi for ${WORKSPACE_NAME}"

  echo "IC: Logging into the cloud"
  ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" -r "${VPC_REGION}"
  retry "ic plugin install -f power-iaas tg-cli vpc-infrastructure cis"

  # Run Cleanup
  cleanup_ibmcloud_powervs "${CLEAN_VERSION}" "${WORKSPACE_NAME}" "${VPC_NAME}"

  echo "IC: Resource Group is ${RESOURCE_GROUP}"
  echo "${RESOURCE_GROUP}" > "${SHARED_DIR}"/RESOURCE_GROUP

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
