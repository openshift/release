#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ "${ADDITIONAL_WORKERS}" == "0" ]; then
    echo "No additional workers requested"
    exit 0
fi

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
function wait_for_nodes_readiness()
{
  local expected_nodes=${1}
  local max_retries=${2:-10}
  local period=${3:-5}
  for i in $(seq 1 "${max_retries}") max; do
    if [ "${i}" == "max" ]; then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      return 1
    fi
    sleep "${period}m"
    ready_nodes=$(get_ready_nodes_count)
    if [ x"${ready_nodes}" == x"${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

EXPECTED_NODES=$(( $(get_ready_nodes_count) + ADDITIONAL_WORKERS ))

echo "Cluster type is ${CLUSTER_TYPE}"

case "$CLUSTER_TYPE" in
*ibmcloud*)
  # Add code for ppc64le
  if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" == "ppc64le" ]; then
      echo "Adding additional ppc64le nodes"
      REGION="${LEASED_RESOURCE}"
      IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
      SERVICE_NAME=power-iaas
      SERVICE_PLAN_NAME=power-virtual-server-group
      WORKSPACE_NAME=rdr-mac-${REGION}-n1

      PATH=${PATH}:/tmp
      mkdir -p ${IBMCLOUD_HOME_FOLDER}
      if [ -z "$(command -v ibmcloud)" ]; then
        echo "ibmcloud CLI doesn't exist, installing"
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
      fi
      
      function ic() {
        HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
      }

      # Check if jq,yq,git and openshift-install are installed
      if [ -z "$(command -v yq)" ]; then
      	echo "yq is not installed, proceed to installing yq"
      	curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
          -o /tmp/yq && chmod +x /tmp/yq
      fi

      if [ -z "$(command -v jq)" ]; then
        echo "jq is not installed, proceed to installing jq"
        curl -L "https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64" -o /tmp/jq && chmod +x /tmp/jq
      fi

      if [ -z "$(command -v openshift-install)" ]; then
        echo "openshift-install is not installed, proceed to installing openshift-install"
        curl -L https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp/stable/ppc64le/openshift-install-linux.tar.gz -o /tmp/openshift-install && chmod +x /tmp/openshift-install
      fi

      # upgrade go to 1.20.7 or greater
      if [ -z "$(command -v go)" ]; then
        echo "go is not installed, proceed to installing go"
        cd /tmp && wget -q https://go.dev/dl/go1.20.7.linux-amd64.tar.gz && tar -C /tmp -xzf go1.20.7.linux-amd64.tar.gz \
          && export PATH=$PATH:/tmp/go/bin && export GOCACHE=/tmp/go && export GOPATH=/tmp/go && export GOMODCACHE="/tmp/go/pkg/mod"
        if [ -z "$(command -v go)" ]; then
          echo "Installed go successfully"
        fi
      fi

      # build terraform from source v1.5.4
      cd ${IBMCLOUD_HOME_FOLDER} && curl -L https://github.com/hashicorp/terraform/archive/refs/tags/v1.5.4.tar.gz -o ${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz \
        && tar -xzf ${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz && cd ${IBMCLOUD_HOME_FOLDER}/terraform-1.5.4 \
        && go build -ldflags "-w -s -X 'github.com/hashicorp/terraform/version.dev=no'" -o bin/ . && cp bin/terraform /tmp/terraform
      export PATH=$PATH:/tmp
      t_ver1=$(/tmp/terraform -version)
      echo "terraform version: ${t_ver1}"

      export PATH
      ic version
      echo "Logging into IBMCLOUD"
      RESOURCE_GROUP=$(yq -r '.platform.ibmcloud.resourceGroupName' ${SHARED_DIR}/install-config.yaml)

      ic login --apikey @${CLUSTER_PROFILE_DIR}/ibmcloud-api-key -r ${REGION} -g ${RESOURCE_GROUP}
      ic plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas is

      # create workspace for power from cli
      echo "Display all the variable values"
      POWERVS_REGION=$(
          case "$REGION" in
              ("jp-osa") echo "osa21" ;;
              ("eu-gb") echo "lon04" ;;
              ("ca-tor") echo "mon01" ;;
              ("br-sao") echo "sao01" ;;
              ("au-syd") echo "syd04" ;;
              ("jp-tok") echo "tok04" ;;
              (*) echo "$REGION" ;;
          esac)
      echo "Region is ${REGION} PowerVS region is ${POWERVS_REGION} Resource Group is ${RESOURCE_GROUP}"
      SERVICE_INSTANCE_OUTPUT=$(ic resource service-instance-create "${WORKSPACE_NAME}" "${SERVICE_NAME}" "${SERVICE_PLAN_NAME}" "${POWERVS_REGION}" -g "${RESOURCE_GROUP}")

      SERVICE_INSTANCE_ID=$(echo "$SERVICE_INSTANCE_OUTPUT" | grep -oE 'GUID:[[:space:]]+[^:[:space:]]+' | awk '{print $2}')

      # Copy the service id to shared_dir to use in deprovisioning step
      echo ${SERVICE_INSTANCE_ID} > ${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID
      cat ${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID

      echo ${RESOURCE_GROUP} > ${SHARED_DIR}/RESOURCE_GROUP
      echo ${OCP_VERSION} > ${SHARED_DIR}/OCP_VERSION

      # After the workspace is created, invoke the automation code
      cd ${IBMCLOUD_HOME_FOLDER} && curl -L https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/release-${OCP_VERSION}.tar.gz -o ${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz \
        && tar -xzf ${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz && mv ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs-release-${OCP_VERSION} ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs

      echo "Creating the Centos Stream Image"
      bash ocp4-upi-compute-powervs/scripts/import-centos.sh /tmp/ibmcloud "${SERVICE_INSTANCE_ID}"

      # Set the values to be used for generating var.tfvars
      IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
      export IC_API_KEY
      export PRIVATE_KEY_FILE=${CLUSTER_PROFILE_DIR}/ssh-privatekey
      export PUBLIC_KEY_FILE=${CLUSTER_PROFILE_DIR}/ssh-publickey
      export POWERVS_SERVICE_INSTANCE_ID=${SERVICE_INSTANCE_ID}
      export INSTALL_CONFIG_FILE=${SHARED_DIR}/install-config.yaml
      export KUBECONFIG=${SHARED_DIR}/kubeconfig

      # Invoke create_var_file.sh to generate var.tfvars file
      echo "Creating the var file"
      cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs && bash scripts/create-var-file.sh /tmp/ibmcloud "${EXPECTED_NODES}"

      # TODO:MAC check if the var.tfvars file is populated
      VARFILE_OUTPUT=$(cat ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/var.tfvars)
      echo "varfile_output is ${VARFILE_OUTPUT}"

      # copy the var.tfvars file and the POWERVS_SERVICE_INSTANCE_ID to ${SHARED_DIR} so that it can be used to destroy the
      # created resources. The FAILED_DEPLOY flag is only exported on a fail
      cp ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/var.tfvars ${SHARED_DIR}/var.tfvars
      cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/ && /tmp/terraform init -upgrade \
        && /tmp/terraform plan -var-file=data/var.tfvars -no-color \
        && /tmp/terraform apply -var-file=data/var.tfvars -auto-approve -no-color \
        || export FAILED_DEPLOY="true"
      
      echo "Shared Directory: copy the terraform.tfstate"
      cp ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/terraform.tfstate ${SHARED_DIR}/terraform.tfstate

      # If the deploy fails, destroy right away and hard exit
      if [ ! -z "${FAILED_DEPLOY}" ]
      then
        # sleep and then try again to clean any failure up.
        cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/ \
          && /tmp/terraform apply -var-file=data/var.tfvars -auto-approve -no-color \
          || sleep 120 && /tmp/terraform apply -var-file=data/var.tfvars -auto-approve -no-color
        echo "Failed to deploy... hard exit"
        exit 1
      fi
  fi
;;
*)
  echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

echo "Wait for the nodes to become ready..."
wait_for_nodes_readiness ${EXPECTED_NODES}
ret="$?"
if [ "${ret}" != "0" ]; then
  echo "Some errors occurred, exiting with ${ret}."
  exit "${ret}"
fi

exit 0