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

export POWERVS_REGION="syd"
export POWERVS_ZONE="syd05"
echo "POWERVS_REGION:- ${POWERVS_REGION}"
echo "POWERVS_ZONE:- ${POWERVS_ZONE}"

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
      error "All retry attempts failed! Please try running the script again after some time" $ret_code
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
  export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-privatekey
  export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-publickey
  export CLUSTER_DOMAIN="${BASE_DOMAIN}"
  export IBMCLOUD_CIS_CRN="${IBMCLOUD_CIS_CRN}"

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
rhcos_image_name    = "${RHCOS_IMAGE_NAME}"
system_type         = "e980"
cluster_domain      = "${CLUSTER_DOMAIN}"
cluster_id_prefix   = "rdr-mac-ci"
bastion   = { memory = "16", processors = "1", "count" = 1 }
bootstrap = { memory = "16", processors = "0.5", "count" = 1 }
master    = { memory = "16", processors = "0.5", "count" = 3 }
worker    = { memory = "16", processors = "0.5", "count" = 2 }
openshift_install_tarball = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp-dev-preview/${OCP_VERSION}/ppc64le/openshift-install-linux.tar.gz"
openshift_client_tarball  = "https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp-dev-preview/${OCP_VERSION}/ppc64le/openshift-client-linux.tar.gz"
release_image_override    = "quay.io/openshift-release-dev/ocp-release:${OCP_VERSION}-multi"
ibm_cloud_cis_crn = "${IBMCLOUD_CIS_CRN}"
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
  ocp_target_version="candidate"
  echo "proceed to re-installing openshift-install"
  curl -L "https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp-dev-preview/${ocp_target_version}/amd64/openshift-install-linux.tar.gz" -o "${IBMCLOUD_HOME_FOLDER}"/openshift-install.tar.gz
  tar -xf "${IBMCLOUD_HOME_FOLDER}"/openshift-install.tar.gz -C "${IBMCLOUD_HOME_FOLDER}"
  cp "${IBMCLOUD_HOME_FOLDER}"/openshift-install /tmp/
  OCP_VERSION="$(/tmp/openshift-install version | head -n 1 | awk '{print $2}')"
  export OCP_VERSION
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

function create_powervs_service_instance() {
  local version="${1}"
  local workspace_name="${2}"
  local powervs_zone="${3}"
  local resource_group="${4}"

  SERVICE_NAME=power-iaas
  SERVICE_PLAN_NAME=power-virtual-server-group

  # create workspace for powervs from cli
  ic resource service-instance-create "${workspace_name}" "${SERVICE_NAME}" "${SERVICE_PLAN_NAME}" "${powervs_zone}" -g "${resource_group}" --allow-cleanup 2>&1 \
  | tee /tmp/instance.id

  # Process the CRN into a variable
  CRN=$(cat /tmp/instance.id | grep crn | awk '{print $NF}')
  export CRN
  echo "${CRN}" > "${SHARED_DIR}"/POWERVS_SERVICE_CRN
  POWERVS_SERVICE_INSTANCE_ID=$(echo "${CRN}" | sed 's|:| |g' | awk '{print $NF}')
  export POWERVS_SERVICE_INSTANCE_ID
  echo "${POWERVS_SERVICE_INSTANCE_ID}" > "${SHARED_DIR}"/POWERVS_SERVICE_INSTANCE_ID
  sleep 30

  # Tag the resource for easier deletion
  ic resource tag-attach --tag-names mac-power-worker-"${CLEAN_VERSION}" --resource-id "${CRN}" --tag-type user

  # Waits for the created instance to become active... after 10 minutes it fails and exists
  # Example content for TEMP_STATE
  # active
  # crn:v1:bluemix:public:power-iaas:osa21:a/3c24cb272ca44aa1ac9f6e9490ac5ecd:6632ebfa-ae9e-4b6c-97cd-c4b28e981c46::
  COUNTER=0
  SERVICE_STATE=""
  while [ -z "${SERVICE_STATE}" ]
  do
    COUNTER=$((COUNTER+1)) 
    TEMP_STATE="$(ic resource service-instance -g "${resource_group}" "${CRN}" --output json | jq -r '.state')"
    echo "Current State is: ${TEMP_STATE}"
    echo ""
    if [ "${TEMP_STATE}" == "active" ]
    then
      SERVICE_STATE="FOUND"
    elif [[ $COUNTER -ge 20 ]]
    then
      SERVICE_STATE="ERROR"
      echo "Service has not come up... login and verify"
      exit 2
    else
      echo "Waiting for service to become active... [30 seconds]"
      sleep 30
    fi
  done

  echo "SERVICE_STATE: ${SERVICE_STATE}"
}

function create_powervs_private_network() {
  local CRN="${1}"

  echo "Creating the Network"
  echo "PowerVS Target CRN is: ${CRN}"
  retry "ic pi st ${CRN}"
  ic pi network-create-private ocp-net --cidr-block 192.168.200.0/24 --ip-range "192.168.200.10-192.168.200.254" -dns-servers "8.8.8.8" --jumbo
}

function import_centos_image() {
  local CRN="${1}"

  # The CentOS-Stream-8 image is stock-image on PowerVS.
  # This image is available across all PowerVS workspaces.
  # The VMs created using this image are used in support of ignition on PowerVS.
  echo "Creating the Centos Stream Image"
  echo "PowerVS Target CRN is: ${CRN}"
  retry "ic pi st ${CRN}"
  retry "ic pi images"
  retry "ic pi image-create CentOS-Stream-8 --json"
  echo "Import image status is: $?"
}

function import_rhcos_image() {
  local CRN="${1}"

  COREOS_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.ppc64le.artifacts.powervs.formats."ova.gz".disk.location')
  COREOS_FILE=$(echo "${COREOS_URL}" | sed 's|/| |g' | awk '{print $NF}')
  COREOS_NAME=$(echo "${COREOS_FILE}" | tr '.' '-' | sed 's|-0-powervs-ppc64le-ova-gz|-0-ppc64le-powervs.ova.gz|g')

  CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
  export RHCOS_IMAGE_NAME=rhcos-"${CLEAN_VERSION}"

  echo "Import the RHCOS Image"
  echo "PowerVS Target CRN is: ${CRN}"
  retry "ic pi st ${CRN}"
  retry "ic pi images"
  ic pi image-import "${RHCOS_IMAGE_NAME}" \
        --bucket-access public --disk-type tier1 \
        --bucket "${BUCKET_NAME}" --region "${BUCKET_REGION}" --job --json --os-type rhel \
        --image-file-name "${COREOS_NAME}"
  echo "Import image status is: $?"

  for COUNT in $(seq 0 10)
  do
    FIND=$(ic pi imgs --json 2> /dev/null | jq -r '.images[].name' | grep  "${RHCOS_IMAGE_NAME}" || true)
    echo "FIND: ${FIND}"
    if [ -n "${FIND}" ]
    then
      echo "Image is imported"
      break
    fi
    echo "waiting for image to get imported ${COUNT}"
    sleep 60
  done
  echo "Done Importing the ${RHCOS_IMAGE_NAME}"

  IMAGE_COUNTER=0
  IMAGE_STATE=""
  while [ -z "${IMAGE_STATE}" ]
  do
  IMAGE_COUNTER=$((COUNTER+1)) 
  TEMP_STATE="$(ic pi img "${RHCOS_IMAGE_NAME}" -json 2> /dev/null | jq -r '.state')"
  echo "Current State is: ${TEMP_STATE}"
  echo ""
  if [ "${TEMP_STATE}" == "active" ]
  then
    IMAGE_STATE="FOUND"
  elif [[ $IMAGE_COUNTER -ge 20 ]]
  then
    IMAGE_STATE="ERROR"
    echo "Image has not come up in active state... login and verify"
    exit 2
  else
    echo "Waiting for image to become active... [30 seconds]"
    sleep 30
  fi
  done
}

echo "Cluster type is ${CLUSTER_TYPE}"

case "$CLUSTER_TYPE" in
*ppc64le*)
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
  WORKSPACE_NAME=rdr-mac-upi-"${CLEAN_VERSION}"-"${POWERVS_ZONE}"-n1
  echo "${WORKSPACE_NAME}" > "${SHARED_DIR}"/WORKSPACE_NAME

  echo "Invoking upi install heterogeneous powervs for ${WORKSPACE_NAME}"

  export RESOURCE_GROUP="${RESOURCE_GROUP}"
  echo "Logging into IBMCLOUD"
  ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -g "${RESOURCE_GROUP}" --no-region
  retry "ic plugin install -f power-iaas"

  # Run Cleanup
  cleanup_ibmcloud_powervs "${CLEAN_VERSION}" "${WORKSPACE_NAME}"

  echo "Resource Group is ${RESOURCE_GROUP}"

  # This CRN is useful when manually destroying.
  echo "${RESOURCE_GROUP}" > "${SHARED_DIR}"/RESOURCE_GROUP

  create_powervs_service_instance "${CLEAN_VERSION}" "${WORKSPACE_NAME}" "${POWERVS_ZONE}" "${RESOURCE_GROUP}"
  create_powervs_private_network "${CRN}"
  import_centos_image "${CRN}"
  import_rhcos_image "${CRN}"
  setup_upi_workspace
  create_upi_tf_varfile
  fix_user_permissions
  create_upi_powervs_cluster
;;
*)
  echo "Creating UPI based PowerVS cluster using ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

exit 0
