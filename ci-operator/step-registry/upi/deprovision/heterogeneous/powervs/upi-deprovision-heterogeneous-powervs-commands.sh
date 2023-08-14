#!/bin/bash

# var.tfvars used to provision the powervs nodes is copied to the ${SHARED_DIR}
echo "Invoking upi deprovision heterogeneous powervs"

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
mkdir -p ${IBMCLOUD_HOME_FOLDER}
REGION="${LEASED_RESOURCE}"

if [ -z "$(command -v ibmcloud)" ]; then
  echo "ibmcloud CLI doesn't exist, installing"
  curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
fi

function ic() {
  HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
}

ic version
ic login --apikey @${CLUSTER_PROFILE_DIR}/ibmcloud-api-key -r ${REGION}
ic plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas is

echo "Check if the var.tfvars exists in ${SHARED_DIR}"
if [ -f "${SHARED_DIR}/var.tfvars" ]
then
  # upgrade go to 1.20.7 or greater
  if [ -z "$(command -v go)" ]; then
    echo "go is not installed, proceed to installing go"
    cd /tmp && wget -q https://go.dev/dl/go1.20.7.linux-amd64.tar.gz && tar -C /tmp -xzf go1.20.7.linux-amd64.tar.gz \
      && export PATH=$PATH:/tmp/go/bin && export GOCACHE=/tmp/go && export GOPATH=/tmp/go && export GOMODCACHE="/tmp/go/pkg/mod"
    if [ -z "$(command -v go)" ]; then
      echo "Installed go successfully"
    fi
  fi

  # build terraform from source v1.5.5
  cd ${IBMCLOUD_HOME_FOLDER} && curl -L https://github.com/hashicorp/terraform/archive/refs/tags/v1.5.5.tar.gz -o ${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz \
    && tar -xzf ${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz && cd ${IBMCLOUD_HOME_FOLDER}/terraform-1.5.5 \
    && go build -ldflags "-w -s -X 'github.com/hashicorp/terraform/version.dev=no'" -o bin/ . && cp bin/terraform /tmp/terraform
  export PATH=$PATH:/tmp
  t_ver1=$(/tmp/terraform -version)
  echo "terraform version: ${t_ver1}"

  echo "Destroy the terraform"
  OCP_VERSION=$(cat ${SHARED_DIR}/OCP_VERSION)
  # Fetch the ocp4-upi-compute-powervs repo to perform deprovisioning
  cd ${IBMCLOUD_HOME_FOLDER} && curl -L https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/release-${OCP_VERSION}.tar.gz -o ${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz \
      && tar -xzf ${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz && mv ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs-release-${OCP_VERSION} ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs
  # copy the var.tfvars file from ${SHARED_DIR}
  cp ${SHARED_DIR}/var.tfvars ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/var.tfvars
  cp ${SHARED_DIR}/terraform.tfstate ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/terraform.tfstate

  # Invoke the destroy command and optimistically run twice due to synchronization issues
  cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs \
    && /tmp/terraform init -upgrade \
    && /tmp/terraform destroy -var-file=var.tfvars -auto-approve -no-color || true \
    && /tmp/terraform destroy -var-file=var.tfvars -auto-approve -no-color
else
  echo "Error: File ${SHARED_DIR}/var.tfvars does not exists."
fi

# Delete the workspace created
if [ -f "${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID" ]
then
  echo "Starting the deslete on the PowerVS resource"
  SERVICE_ID=$(cat ${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID)
  if [ -f "${SHARED_DIR}/RESOURCE_GROUP" ]
  then
    RESOURCE_GROUP=$(cat ${SHARED_DIR}/RESOURCE_GROUP)
    ic resource service-instance-delete ${SERVICE_ID} -g ${RESOURCE_GROUP} --force --recursive
  else
    echo "WARNING- No RESOURCE_GROUP or POWERVS_SERVICE_INSTANCE_ID found, not deleting the workspace"
  fi
fi

echo "IBM Cloud PowerVS resources destroyed successfully"