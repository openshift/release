#!/bin/bash

set -o nounset

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud

if [ "${ADDITIONAL_WORKERS}" == "0" ]
then
    echo "No additional workers requested"
    exit 0
fi

function ic() {
  HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
}

# Cleans up the failed prior jobs
function cleanup_ibmcloud_powervs() {
  local version="${1}"
  local workspace_name="${2}"
  local region="${3}"
  local resource_group="${4}"
  local api_key="${5}"
  echo "Cleaning up prior runs - version: ${version} - workspace_name: ${workspace_name}"

  echo "Cleaning up the Transit Gateways"
  RESOURCE_GROUP_ID=$(ic resource groups --output json | jq -r '.[] | select(.name == "'${resource_group}'").id')
  for GW in $(ic tg gateways --output json | jq -r '.[].id')
  do
    echo "Checking the resource_group and location for the transit gateways ${GW}"
    VALID_GW=$(ic tg gw "${GW}" --output json | jq -r '. | select(.resource_group.id == "'$RESOURCE_GROUP_ID'" and .location == "'$region'")')
    if [ -n "${VALID_GW}" ]
    then
      TG_CRN=$(echo "${VALID_GW}" | jq -r '.crn')
      TAGS=$(ic resource search "crn:\"${TG_CRN}\"" --output json | jq -r '.items[].tags[]' | grep "mac-cicd-${version}" || true )
      if [ -n "${TAGS}" ]
      then
        for CS in $(ic tg connections "${GW}" --output json | jq -r '.[].id')
        do 
          ic tg connection-delete "${GW}" "${CS}" --force || true
          sleep 120
          ic tg connection-delete "${GW}" "${CS}" --force || true
          sleep 30
        done
        ic tg gwd "${GW}" --force || sleep 120s || true
        ic tg gateway "${GW}" || true
        ic tg gwd "${GW}" --force || sleep 120s || true
        echo "waiting up a minute while the Transit Gateways are removed"
        sleep 60
      fi
    fi
  done

  echo "reporting out the remaining TGs in the resource_group and region"
  ic tg gws --output json | jq -r '.[] | select(.resource_group.id == "'$RESOURCE_GROUP_ID'" and .location == "'$region'")'

  echo "Cleaning up workspaces for ${workspace_name}"
  for CRN in $(ic pi sl 2> /dev/null | grep "${workspace_name}" | awk '{print $1}' || true)
  do
    echo "Targetting power cloud instance"
    ic pi st "${CRN}"

    echo "Deleting the PVM Instances"
    for INSTANCE_ID in $(ic pi ins --json | jq -r '.pvmInstances[].pvmInstanceID')
    do
      echo "Deleting PVM Instance ${INSTANCE_ID}"
      ic pi ind "${INSTANCE_ID}" --delete-data-volumes
      sleep 60
    done

    echo "Deleting the Images"
    for IMAGE_ID in $(ic pi imgs --json | jq -r '.images[].imageID')
    do
      echo "Deleting Images ${IMAGE_ID}"
      ic pi image-delete "${IMAGE_ID}"
      sleep 60
    done

    if [ -n "$(ic pi nets 2> /dev/null | grep DHCP || true)" ]
    then
       curl -L -o /tmp/pvsadm "https://github.com/ppc64le-cloud/pvsadm/releases/download/v0.1.12/pvsadm-linux-amd64"
       chmod +x /tmp/pvsadm

       POWERVS_SERVICE_INSTANCE_ID=$(echo "${CRN}" | sed 's|:| |g' | awk '{print $NF}')

       NET_ID=$(IC_API_KEY="${api_key}" /tmp/pvsadm dhcpserver list --instance-id ${POWERVS_SERVICE_INSTANCE_ID} --skip_headers --one_output | awk '{print $2}' | grep -v ID | grep -v '|' | sed '/^$/d' || true)
       IC_API_KEY="${api_key}" /tmp/pvsadm dhcpserver delete --instance-id ${POWERVS_SERVICE_INSTANCE_ID} --id "${NET_ID}" || true
       sleep 60
    fi

    echo "Deleting the Network"
    for NETWORK_ID in $(ic pi nets 2> /dev/null | awk '{print $1}')
    do
      echo "Deleting network ${NETWORK_ID}"
      ic pi network-delete "${NETWORK_ID}" || true
      sleep 60
    done

    echo "Updating the service instance"
    ic resource service-instance-update "${CRN}" --allow-cleanup true || true
    sleep 30
    echo "Deleting the service instance"
    ic resource service-instance-delete "${CRN}" --force --recursive || true
    for COUNT in $(seq 0 5)
    do
      FIND=$(ibmcloud pi sl 2> /dev/null| grep "${CRN}" || true)
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
      # Saving the OCP VERSION so we can use in a subsequent deprovision
      echo "${OCP_VERSION}" > "${SHARED_DIR}"/OCP_VERSION

      echo "Adding additional ppc64le nodes"
      REGION="${LEASED_RESOURCE}"
      IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
      SERVICE_NAME=power-iaas
      SERVICE_PLAN_NAME=power-virtual-server-group

      # Generates a workspace name like rdr-mac-4-14-au-syd-n1
      # this keeps the workspace unique
      CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
      WORKSPACE_NAME=rdr-mac-${CLEAN_VERSION}-${REGION}-n1

      PATH=${PATH}:/tmp
      mkdir -p ${IBMCLOUD_HOME_FOLDER}
      if [ -z "$(command -v ibmcloud)" ]
      then
        echo "ibmcloud CLI doesn't exist, installing"
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
      fi

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

      # short-circuit to download and install terraform
      echo "Attempting to install terraform using gzip"
      curl -L -o "${IBMCLOUD_HOME_FOLDER}"/terraform.gz -L https://releases.hashicorp.com/terraform/"${TERRAFORM_VERSION}"/terraform_"${TERRAFORM_VERSION}"_linux_amd64.zip \
        && gunzip "${IBMCLOUD_HOME_FOLDER}"/terraform.gz \
        && chmod +x "${IBMCLOUD_HOME_FOLDER}"/terraform \
        || true

      if [ ! -f "${IBMCLOUD_HOME_FOLDER}"/terraform ]
      then
        echo "Manually building the terraform code"
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
        echo "terraform is not installed, proceed to installing terraform"
        cd "${IBMCLOUD_HOME_FOLDER}" && curl -L https://github.com/hashicorp/terraform/archive/refs/tags/v"${TERRAFORM_VERSION}".tar.gz -o "${IBMCLOUD_HOME_FOLDER}"/terraform.tar.gz \
          && tar -xzf "${IBMCLOUD_HOME_FOLDER}"/terraform.tar.gz && cd "${IBMCLOUD_HOME_FOLDER}"/terraform-"${TERRAFORM_VERSION}" \
          && go build -ldflags "-w -s -X 'github.com/hashicorp/terraform/version.dev=no'" -o bin/ . && cp bin/terraform "${IBMCLOUD_HOME_FOLDER}"/terraform
      fi

      export PATH=$PATH:/tmp:/"${IBMCLOUD_HOME_FOLDER}"
      t_ver1=$(${IBMCLOUD_HOME_FOLDER}/terraform -version)
      echo "terraform version: ${t_ver1}"

      export PATH
      ic version
      echo "Logging into IBMCLOUD"
      RESOURCE_GROUP=$(yq -r '.platform.ibmcloud.resourceGroupName' "${SHARED_DIR}/install-config.yaml")

      ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -r "${REGION}" -g "${RESOURCE_GROUP}"
      ic plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas is tg

      # Run Cleanup
      cleanup_ibmcloud_powervs "${CLEAN_VERSION}" "${WORKSPACE_NAME}" "${REGION}" "${RESOURCE_GROUP}" "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"

      # Before the workspace is created, download the automation code
      # release-4.14-per
      cd "${IBMCLOUD_HOME_FOLDER}" \
        && curl -L https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/release-"${OCP_VERSION}"-per.tar.gz -o "${IBMCLOUD_HOME_FOLDER}"/ocp-"${OCP_VERSION}".tar.gz \
        && tar -xzf "${IBMCLOUD_HOME_FOLDER}"/ocp-"${OCP_VERSION}".tar.gz \
        && mv "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs-release-${OCP_VERSION}-per" "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs

      # create workspace for powervs from cli
      echo "Display all the variable values:"
      POWERVS_REGION=$(bash "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/scripts/region.sh "${REGION}")
      echo "VPC Region is ${REGION}"
      echo "PowerVS region is ${POWERVS_REGION}"
      echo "Resource Group is ${RESOURCE_GROUP}"
      ic resource service-instance-create "${WORKSPACE_NAME}" "${SERVICE_NAME}" "${SERVICE_PLAN_NAME}" "${POWERVS_REGION}" -g "${RESOURCE_GROUP}" --allow-cleanup 2>&1 \
        | tee /tmp/instance.id

      # Process the CRN into a variable
      CRN=$(cat /tmp/instance.id | grep crn | awk '{print $NF}')
      export CRN
      echo "${CRN}" > "${SHARED_DIR}"/POWERVS_SERVICE_CRN
      sleep 30

      # Tag the resource for easier deletion
      ic resource tag-attach --tag-names "mac-power-worker-${CLEAN_VERSION}" --resource-id "${CRN}" --tag-type user

      # Waits for the created instance to become active... after 10 minutes it fails and exists
      # Example content for TEMP_STATE
      # active
      # crn:v1:bluemix:public:power-iaas:osa21:a/3c24cb272ca44aa1ac9f6e9490ac5ecd:6632ebfa-ae9e-4b6c-97cd-c4b28e981c46::
      COUNTER=0
      SERVICE_STATE=""
      while [ -z "${SERVICE_STATE}" ]
      do
        COUNTER=$((COUNTER+1)) 
        TEMP_STATE="NOT_READY"
        if [ "$(ibmcloud resource search "crn:\"${CRN}\"" --output json | jq -r '.items | length')" != "0" ]
        then
            TEMP_STATE="$(ic resource service-instance -g "${RESOURCE_GROUP}" "${CRN}" --output json --type service_instance  | jq -r '.[].state')"
        fi
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
        && bash scripts/create-var-file.sh /tmp/ibmcloud "${ADDITIONAL_WORKERS}" "${CLEAN_VERSION}"

      # TODO:MAC check if the var.tfvars file is populated
      VARFILE_OUTPUT=$(cat "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/data/var.tfvars)
      echo "varfile_output is ${VARFILE_OUTPUT}"

      # copy the var.tfvars file and the POWERVS_SERVICE_CRN to ${SHARED_DIR} so that it can be used to destroy the
      # created resources.
      cp "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/data/var.tfvars "${SHARED_DIR}"/var.tfvars

      cd "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/ \
        && "${IBMCLOUD_HOME_FOLDER}"/terraform init -upgrade -no-color \
        && "${IBMCLOUD_HOME_FOLDER}"/terraform plan -var-file=data/var.tfvars -no-color \
        && "${IBMCLOUD_HOME_FOLDER}"/terraform apply -var-file=data/var.tfvars -auto-approve -no-color \
        || cp -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/terraform.tfstate "${SHARED_DIR}"/terraform.tfstate

      echo "Shared Directory: copy the terraform.tfstate"
      cp -f "${IBMCLOUD_HOME_FOLDER}"/ocp4-upi-compute-powervs/terraform.tfstate "${SHARED_DIR}"/terraform.tfstate
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