#!/bin/bash

set -o nounset

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ "${ADDITIONAL_WORKERS}" == "0" ]
then
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
  for i in $(seq 1 "${max_retries}") max
  do
    if [ "${i}" == "max" ]
    then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      return 1
    fi
    sleep "${period}m"
    ready_nodes=$(get_ready_nodes_count)
    if [ "${ready_nodes}" == "${expected_nodes}" ]
    then
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
  if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" == "ppc64le" ]
  then
      echo "Adding additional ppc64le nodes"
      REGION="${LEASED_RESOURCE}"
      IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
      SERVICE_NAME=power-iaas
      SERVICE_PLAN_NAME=power-virtual-server-group
      WORKSPACE_NAME=rdr-mac-${REGION}-n1

      PATH=${PATH}:/tmp
      mkdir -p ${IBMCLOUD_HOME_FOLDER}
      if [ -z "$(command -v ibmcloud)" ]
      then
        echo "ibmcloud CLI doesn't exist, installing"
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
      fi
      
      function ic() {
        HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
      }

      # Check if jq,yq,git and openshift-install are installed
      if [ -z "$(command -v yq)" ]
      then
      	echo "yq is not installed, proceed to installing yq"
      	curl -L "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
          -o /tmp/yq && chmod +x /tmp/yq
      fi

      if [ -z "$(command -v jq)" ]
      then
        echo "jq is not installed, proceed to installing jq"
        curl -L "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux64" -o /tmp/jq && chmod +x /tmp/jq
      fi

      if [ -z "$(command -v openshift-install)" ]
      then
        echo "openshift-install is not installed, proceed to installing openshift-install"
        curl -L https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp/stable/ppc64le/openshift-install-linux.tar.gz \
          -o /tmp/openshift-install && chmod +x /tmp/openshift-install
      fi

      # upgrade go to GO_VERSION
      if [ -z "$(command -v go)" ]
      then
        echo "go is not installed, proceed to installing go"
        cd /tmp && wget -q https://go.dev/dl/go"${GO_VERSION}".linux-amd64.tar.gz && tar -C /tmp -xzf go"${GO_VERSION}".linux-amd64.tar.gz \
          && export PATH=$PATH:/tmp/go/bin && export GOCACHE=/tmp/go && export GOPATH=/tmp/go && export GOMODCACHE="/tmp/go/pkg/mod"
        if [ -z "$(command -v go)" ]
        then
          echo "Installed go successfully"
        fi
      fi

      # build terraform from source using TERRAFORM_VERSION
      cd "${IBMCLOUD_HOME_FOLDER}" && curl -L https://github.com/hashicorp/terraform/archive/refs/tags/v"${TERRAFORM_VERSION}".tar.gz -o "${IBMCLOUD_HOME_FOLDER}"/terraform.tar.gz \
        && tar -xzf "${IBMCLOUD_HOME_FOLDER}"/terraform.tar.gz && cd "${IBMCLOUD_HOME_FOLDER}"/terraform-"${TERRAFORM_VERSION}" \
        && go build -ldflags "-w -s -X 'github.com/hashicorp/terraform/version.dev=no'" -o bin/ . && cp bin/terraform /tmp/terraform
      export PATH=$PATH:/tmp
      t_ver1=$(/tmp/terraform -version)
      echo "terraform version: ${t_ver1}"

      export PATH
      ic version
      echo "Logging into IBMCLOUD"
      RESOURCE_GROUP=$(yq -r '.platform.ibmcloud.resourceGroupName' "${SHARED_DIR}/install-config.yaml")

      ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -r "${REGION}" -g "${RESOURCE_GROUP}"
      ic plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas is

      # Before the workspace is created, download the automation code
      cd "${IBMCLOUD_HOME_FOLDER}" \
        && curl -L https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/release-"${OCP_VERSION}".tar.gz -o "${IBMCLOUD_HOME_FOLDER}"/ocp-"${OCP_VERSION}".tar.gz \
        && tar -xzf "${IBMCLOUD_HOME_FOLDER}"/ocp-"${OCP_VERSION}".tar.gz \
        && mv "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs-release-${OCP_VERSION}" "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs

      # create workspace for powervs from cli
      echo "Display all the variable values:"
      POWERVS_REGION=$(bash "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/scripts/region.sh "${REGION}")
      echo "VPC Region is ${REGION}"
      echo "PowerVS region is ${POWERVS_REGION}"
      echo "Resource Group is ${RESOURCE_GROUP}"
      ic resource service-instance-create "${WORKSPACE_NAME}" "${SERVICE_NAME}" "${SERVICE_PLAN_NAME}" "${POWERVS_REGION}" -g "${RESOURCE_GROUP}" 2>&1 \
        | tee /tmp/instance.id
      
      # Process the CRN into a variable
      CRN=$(cat /tmp/instance.id | grep crn | awk '{print $NF}')
      export CRN
      echo "${CRN}" > "${SHARED_DIR}"/POWERVS_SERVICE_CRN
      sleep 30

      # Tag the resource for easier deletion
      ic resource tag-attach --tag-names "mac-power-worker" --resource-id "${CRN}" --tag-type user

      # Waits for the created instance to become active... after 10 minutes it fails and exists
      # Example content for TEMP_STATE
      # active
      # crn:v1:bluemix:public:power-iaas:osa21:a/3c24cb272ca44aa1ac9f6e9490ac5ecd:6632ebfa-ae9e-4b6c-97cd-c4b28e981c46::
      COUNTER=0
      SERVICE_STATE=""
      while [ -z "${SERVICE_STATE}" ]
      do
        COUNTER=$((COUNTER+1)) 
        TEMP_STATE="$(ic resource service-instances -g "${RESOURCE_GROUP}" --output json --type service_instance  | jq -r '.[] | select(.crn == "'"${CRN}"'") | .state')"
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

      # This CRN is useful when manually destroying.
      echo "PowerVS Service CRN: ${CRN}"

      echo "${RESOURCE_GROUP}" > "${SHARED_DIR}"/RESOURCE_GROUP
      echo "${OCP_VERSION}" > "${SHARED_DIR}"/OCP_VERSION

      # The CentOS-Stream-8 image is stock-image on PowerVS.
      # This image is available across all PowerVS workspaces.
      # The VMs created using this image are used in support of ignition on PowerVS.
      echo "Creating the Centos Stream Image"
      echo "PowerVS Target CRN is: ${CRN}"
      ic pi st "${CRN}"
      ic pi images
      ic pi image-create CentOS-Stream-8 --json
      echo "Import image status is: $?"

      # Set the values to be used for generating var.tfvars
      POWERVS_SERVICE_INSTANCE_ID=$(echo "${CRN}" | sed 's|:| |g' | awk '{print $NF}')
      export POWERVS_SERVICE_INSTANCE_ID
      IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
      export IC_API_KEY
      export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-privatekey
      export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}"/ssh-publickey
      export INSTALL_CONFIG_FILE=${SHARED_DIR}/install-config.yaml
      export KUBECONFIG=${SHARED_DIR}/kubeconfig

      # Invoke create-var-file.sh to generate var.tfvars file
      echo "Creating the var file"
      cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs \
        && bash scripts/create-var-file.sh /tmp/ibmcloud "${ADDITIONAL_WORKERS}"

      # TODO:MAC check if the var.tfvars file is populated
      VARFILE_OUTPUT=$(cat "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/data/var.tfvars)
      echo "varfile_output is ${VARFILE_OUTPUT}"

      # copy the var.tfvars file and the POWERVS_SERVICE_CRN to ${SHARED_DIR} so that it can be used to destroy the
      # created resources. The FAILED_DEPLOY flag is only exported on a fail
      FAILED_DEPLOY=""
      cp "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/data/var.tfvars "${SHARED_DIR}"/var.tfvars
      cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/ \
        && /tmp/terraform init -upgrade -no-color \
        && /tmp/terraform plan -var-file=data/var.tfvars -no-color \
        && /tmp/terraform apply -var-file=data/var.tfvars -auto-approve -no-color \
        || export FAILED_DEPLOY="true"

      echo "Shared Directory: copy the terraform.tfstate"
      cp "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/terraform.tfstate "${SHARED_DIR}"/terraform.tfstate

      # If the deploy fails, hard exit
      if [ -n "${FAILED_DEPLOY}" ]
      then
        echo "Failed to deploy... hard exit... deprovisioning now to more cleanly exit"
        cd "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs" \
          && /tmp/terraform init -upgrade -no-color \
          && /tmp/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
          || sleep 120 \
          || /tmp/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
          || true
        echo "cleaning up workspace"
        ic resource service-instance-delete "${POWERVS_SERVICE_INSTANCE_ID}" -g "${RESOURCE_GROUP}" --force --recursive \
          || true
        exit 1
      else
        echo "Worker Status is: "
        oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
        echo "Cluster Operator is: "
        oc get co
        IDX=0
        while [ "$IDX" -lt "121" ]
        do
            FAL_COUNT=$(oc get co -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' | grep False | wc -l)
            if [ "${FAL_COUNT}" -eq "0" ]
            then
              break
            fi
            if [ "${IDX}" -eq "60" ]
            then
              echo "Exceeded the wait time of >120 minutes"
              exit 3
            fi
            oc get co -o yaml
            echo "waiting for the cluster operators to return to operation"
            sleep 60
            IDX=$(($IDX + 1))
        done
        
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
if [ "${ret}" != "0" ]
then
  echo "Some errors occurred, exiting with ${ret}."
  exit "${ret}"
fi

exit 0