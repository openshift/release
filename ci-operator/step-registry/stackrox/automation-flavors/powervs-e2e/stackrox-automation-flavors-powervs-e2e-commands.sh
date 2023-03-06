#!/bin/bash

#set -o nounset
set -o errexit
set -o pipefail

if [[ -z $1 ]]; then
  echo "Please provide 'create' or 'delete' action."
  exit 1
fi

ACTION="$1"
LAST_WORK_DIR="$(pwd)"
POWERVS_OCP_DIR="/tmp/powervs-ocp"
SECRET_DIR="/tmp/vault/powervs-rhr-creds"

# tmp dir for cluster files
mkdir -p "$POWERVS_OCP_DIR"
cd "$POWERVS_OCP_DIR"

# OCP Version
export RELEASE_VER="4.11"
export RELEASE_VER_TAG="stable-4.11"

# populate secrets
SERVICE_INSTANCE_ID="$(cat "${SECRET_DIR}/SERVICE_INSTANCE_ID")"
IBMCLOUD_API_KEY="$(cat "${SECRET_DIR}/IBMCLOUD_API_KEY")"
RHEL_SUBSCRIPTION_USERNAME="$(cat "${SECRET_DIR}/RHEL_SUBSCRIPTION_USERNAME")"
RHEL_SUBSCRIPTION_PASSWORD="$(cat "${SECRET_DIR}/RHEL_SUBSCRIPTION_PASSWORD")"
PULL_SECRET_FILE="${SECRET_DIR}/PULL_SECRET_FILE"
PRIVATE_KEY_FILE="${SECRET_DIR}/PRIVATE_KEY_FILE"
PUBLIC_KEY_FILE="${SECRET_DIR}/PUBLIC_KEY_FILE"

create_tfvars_file(){

cat > "${POWERVS_OCP_DIR}/var.tfvars" << EOF
## IBM cloud configurations
ibmcloud_region = "mon"
ibmcloud_zone = "mon01"
service_instance_id = "${SERVICE_INSTANCE_ID}"
ibmcloud_api_key = "${IBMCLOUD_API_KEY}"
rhel_image_name =  "rhel-86-05162022-tier1"
rhcos_image_name =  "rhcos-411-03092022-tier1"
system_type =  "s922"
network_name =  "ocp-private-network"

openshift_install_tarball =  "https://mirror.openshift.com/pub/openshift-v4/ppc64le/clients/ocp/${RELEASE_VER_TAG}/openshift-install-linux.tar.gz"
openshift_client_tarball =  "https://mirror.openshift.com/pub/openshift-v4/ppc64le/clients/ocp/${RELEASE_VER_TAG}/openshift-client-linux.tar.gz"
pull_secret_file = "${POWERVS_OCP_DIR}/pull-secret.txt"
private_key_file  = "${POWERVS_OCP_DIR}/id_rsa"
public_key_file  = "${POWERVS_OCP_DIR}/id_rsa.pub"
rhel_subscription_username = "${RHEL_SUBSCRIPTION_USERNAME}"
rhel_subscription_password = "${RHEL_SUBSCRIPTION_PASSWORD}"

## Small Configuration Template
bastion   = { memory = "16", processors = "0.5", "count" = 1 }
bootstrap = { memory = "32", processors = "0.5", "count" = 1 }
master    = { memory = "32", processors = "0.5", "count" = 3 }
worker    = { memory = "32", processors = "0.5", "count" = 2 }
storage_type = "nfs"
volume_size = "200"
cluster_id_prefix = "ci-ocp"
cluster_domain = "nip.io"
EOF

}

setup_automation(){
  curl https://raw.githubusercontent.com/ocp-power-automation/openshift-install-power/devel/openshift-install-powervs --output openshift-install-powervs --silent
  chmod +x openshift-install-powervs
    
  ./openshift-install-powervs setup &> "${POWERVS_OCP_DIR}/setup-log.txt"
  
  cp -f ${PULL_SECRET_FILE} ${POWERVS_OCP_DIR}/pull-secret.txt
  cp -f ${PUBLIC_KEY_FILE} ${POWERVS_OCP_DIR}/id_rsa.pub
  cp -f ${PRIVATE_KEY_FILE} ${POWERVS_OCP_DIR}/id_rsa
  chmod 400 ${POWERVS_OCP_DIR}/id_rsa
  
}

function on_exit(){
  (
  cp -f "${POWERVS_OCP_DIR}/automation/kubeconfig" "${SHARED_DIR}/kubeconfig" || true
  cp -f "${POWERVS_OCP_DIR}/automation/terraform.tfstate" "${SHARED_DIR}/terraform.tfstate" || true
  cp -f "${POWERVS_OCP_DIR}/automation/tfplan" "${SHARED_DIR}/tfplan" || true
  ) &> /dev/null
}

trap on_exit EXIT


if [ "$ACTION" == "create" ]
then
  echo "Creating cluster..."
  
  echo "Setting up automation..."
  setup_automation
  
  echo "Setting up cluster configurations..."
  create_tfvars_file
  
  echo "Deploying cluster..."
  ./openshift-install-powervs create &> "${POWERVS_OCP_DIR}/create-log.txt"
  
  echo "Copy cluster files..."
  # https://docs.ci.openshift.org/docs/architecture/step-registry/#sharing-data-between-steps
  cp -f "${POWERVS_OCP_DIR}/automation/kubeconfig" "${SHARED_DIR}/kubeconfig"
  cp -f "${POWERVS_OCP_DIR}/automation/terraform.tfstate" "${SHARED_DIR}/terraform.tfstate"
  cp -f "${POWERVS_OCP_DIR}/automation/tfplan" "${SHARED_DIR}/tfplan"
  ls -l "$SHARED_DIR/" # DEBUG
  
  echo "Validating cluster access..."
  KUBECONFIG="${SHARED_DIR}/kubeconfig" ./oc get nodes
  
  echo "Cluster created successfully."
elif [ "$ACTION" == "destroy" ]
then
  echo "Destroying cluster..."
  ls -l "$SHARED_DIR/" # DEBUG
  
  echo "Setting up automation..."
  setup_automation
  
  echo "Setting up cluster configurations..."
  create_tfvars_file
  
  echo "Configure automation to destroy cluster..."
  cp -f "${SHARED_DIR}/kubeconfig" "${POWERVS_OCP_DIR}/automation/kubeconfig"
  cp -f "${SHARED_DIR}/terraform.tfstate" "${POWERVS_OCP_DIR}/automation/terraform.tfstate"
  cp -f "${SHARED_DIR}/tfplan" "${POWERVS_OCP_DIR}/automation/tfplan"
  cd ./automation
  if [[ "$(uname -m)" == "ppc64le" ]]; then
    ../terraform init --plugin-dir ../ > /dev/null
  else
    ../terraform init > /dev/null
  fi
  cd ../
  
  echo "Removing cloud resources..."
  NO_OF_RETRY=1 ./openshift-install-powervs destroy -force-destroy &> "${POWERVS_OCP_DIR}/destroy-log.txt"
  
  # temporary workaround: https://github.com/ocp-power-automation/openshift-install-power/issues/208 
  cd ./automation
  ../terraform state rm 'module.prepare.ibm_pi_volume.volume[0]' || true
  cd ../
  ./openshift-install-powervs destroy -force-destroy &> "${POWERVS_OCP_DIR}/destroy-log.txt"
  
  echo "Cluster destroyed successfully."
fi

cd "$LAST_WORK_DIR"
