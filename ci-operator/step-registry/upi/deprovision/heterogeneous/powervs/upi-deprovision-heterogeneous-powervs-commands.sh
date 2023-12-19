#!/bin/bash

# Generates a workspace name like rdr-mac-4-14-au-syd-n1
# this keeps the workspace unique per version
OCP_VERSION=$(cat "${SHARED_DIR}/OCP_VERSION")
REGION="${LEASED_RESOURCE}"
CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')
WORKSPACE_NAME=rdr-mac-${CLEAN_VERSION}-${REGION}-n1

# Cleans up the failed prior jobs
function cleanup_ibmcloud_powervs() {
  local version="${CLEAN_VERSION}"
  local workspace_name="${WORKSPACE_NAME}"
  local region="${REGION}"
  local resource_group="${1}"
  local api_key="@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
  echo "Cleaning up prior runs - version: ${version} - workspace_name: ${workspace_name}"

  echo "Cleaning up the Transit Gateways"
  RESOURCE_GROUP_ID=$(ic resource groups --output json | jq -r '.[] | select(.name == "'${resource_group}'").id')
  for GW in $(ic tg gateways --output json | jq -r '.[].id')
  do
    echo "Checking the resource_group and location for the transit gateways ${GW}"
    VALID_GW=$(ic tg gw "${GW}" --output json | jq -r '. | select(.resource_group.id == "'$RESOURCE_GROUP_ID'" and .location == "'$region'")' || true)
    if [ -n "${VALID_GW}" ]
    then
      TG_CRN=$(echo "${VALID_GW}" | jq -r '.crn')
      TAGS=$(ic resource search "crn:\"${TG_CRN}\"" --output json | jq -r '.items[].tags[]' | grep "mac-cicd-${version}" || true)
      if [ -n "${TAGS}" ]
      then
        for CS in $(ic tg connections "${GW}" --output json | jq -r '.[].id')
        do 
          ic tg connection-delete "${GW}" "${CS}" --force && sleep 120
          ic tg connection "${GW}" "${CS}" \
            || tg connection-delete "${GW}" "${CS}" --force \
            && true && sleep 30
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
  for CRN in $(ic pi sl 2> /dev/null | grep "${workspace_name}" | awk '{print $1}')
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

    if [ -n "$(ic pi nets 2> /dev/null | grep DHCP)" ]
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

    ic resource service-instance-update "${CRN}" --allow-cleanup true
    sleep 30
    ic resource service-instance-delete "${CRN}" --force --recursive
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

# var.tfvars used to provision the powervs nodes is copied to the ${SHARED_DIR}
echo "Invoking upi deprovision heterogeneous powervs for ${WORKSPACE_NAME}"

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
mkdir -p "${IBMCLOUD_HOME_FOLDER}"

if [ -z "$(command -v ibmcloud)" ]
then
  echo "ibmcloud CLI doesn't exist, installing"
  curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
fi

function ic() {
  HOME="${IBMCLOUD_HOME_FOLDER}" ibmcloud "$@"
}

ic version
ic login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -r "${REGION}"
ic plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas is tg-cli

echo "Check if the terraform.tfstate exists in ${SHARED_DIR}"
if [ -f "${SHARED_DIR}/terraform.tfstate" ]
then
  # The must-gather chain can not be called twice, as the ibmcloud embeds must-gather in deprovision
  # we must call must-gather specific to ppc64le at this location.
  MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"15m"}
  MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-""}
  oc get nodes -l kubernetes.io/arch=ppc64le -o yaml > "${ARTIFACT_DIR}"/nodes_with_ppc64le.txt || true
  mkdir -p ${ARTIFACT_DIR}/must-gather-ppc64le
  oc adm must-gather \
      --node-selector=kubernetes.io/arch=ppc64le \
      --insecure-skip-tls-verify $MUST_GATHER_IMAGE \
      --timeout=$MUST_GATHER_TIMEOUT \
      --dest-dir ${ARTIFACT_DIR}/must-gather-ppc64le > ${ARTIFACT_DIR}/must-gather-ppc64le/must-gather-ppc64le.log \
      || true
  tar -czC "${ARTIFACT_DIR}/must-gather-ppc64le" -f "${ARTIFACT_DIR}/must-gather-ppc64le.tar.gz" .
  rm -rf "${ARTIFACT_DIR}"/must-gather-ppc64le

  # short-circuit to download and install terraform
  curl -o "${IBMCLOUD_HOME_FOLDER}"/terraform.gz -L https://releases.hashicorp.com/terraform/"${TERRAFORM_VERSION}"/terraform_"${TERRAFORM_VERSION}"_linux_amd64.zip \
    && gunzip "${IBMCLOUD_HOME_FOLDER}"/terraform.gz \
    && chmod +x "${IBMCLOUD_HOME_FOLDER}"/terraform \
    || true

  # build terraform
  if [ ! -f "${IBMCLOUD_HOME_FOLDER}"/terraform ]
  then
    # upgrade go to GO_VERSION
    if [ -z "$(command -v go)" ]
    then
      echo "go is not installed, proceed to installing go"
      cd /tmp && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
        && tar -C /tmp -xzf "go${GO_VERSION}.linux-amd64.tar.gz" \
        && export PATH=$PATH:/tmp/go/bin:"${IBMCLOUD_HOME_FOLDER}" && export GOCACHE=/tmp/go && export GOPATH=/tmp/go && export GOMODCACHE="/tmp/go/pkg/mod"
      if [ -z "$(command -v go)" ]
      then
        echo "Installed go successfully"
      fi
    fi
    cd "${IBMCLOUD_HOME_FOLDER}" \
      && curl -L "https://github.com/hashicorp/terraform/archive/refs/tags/v${TERRAFORM_VERSION}.tar.gz" \
        -o "${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz" \
      && tar -xzf "${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz" \
      && cd "${IBMCLOUD_HOME_FOLDER}/terraform-${TERRAFORM_VERSION}" \
      && go build -ldflags "-w -s -X 'github.com/hashicorp/terraform/version.dev=no'" -o bin/ . \
      && cp bin/terraform "${IBMCLOUD_HOME_FOLDER}"/terraform
  fi

  export PATH=$PATH:/tmp:"${IBMCLOUD_HOME_FOLDER}"
  t_ver1=$("${IBMCLOUD_HOME_FOLDER}"/terraform -version)
  echo "terraform version: ${t_ver1}"

  echo "Destroy the terraform"
  # Fetch the ocp4-upi-compute-powervs repo to perform deprovisioning
  cd "${IBMCLOUD_HOME_FOLDER}" && curl -L "https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/release-${OCP_VERSION}-per.tar.gz" -o "${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz" \
      && tar -xzf "${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz" \
      && mv "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs-release-${OCP_VERSION}-per" "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs"
  # copy the var.tfvars file from ${SHARED_DIR}
  cp "${SHARED_DIR}/var.tfvars" ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/var.tfvars
  cp "${SHARED_DIR}/terraform.tfstate" ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/terraform.tfstate

  # Copy over the key files and kubeconfig
  export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-publickey"
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  cp "${PUBLIC_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/id_rsa.pub"
  cp "${PRIVATE_KEY_FILE}" "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/id_rsa"
  cp "${KUBECONFIG}" "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/kubeconfig"

  # Invoke the destroy command
  cd "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs" \
    && "${IBMCLOUD_HOME_FOLDER}"/terraform init -upgrade -no-color \
    && "${IBMCLOUD_HOME_FOLDER}"/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
    || sleep 30 \
    || "${IBMCLOUD_HOME_FOLDER}"/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
    || true
else
  echo "Error: File ${SHARED_DIR}/var.tfvars does not exists."
fi

# Delete the workspace created
if [ -f "${SHARED_DIR}/POWERVS_SERVICE_CRN" ]
then
  echo "Starting the delete on the PowerVS resource"
  POWERVS_CRN=$(< "${SHARED_DIR}/POWERVS_SERVICE_CRN")
  POWERVS_SERVICE_INSTANCE_ID=$(echo "${POWERVS_CRN}" | sed 's|:| |g' | awk '{print $NF}')
  if [ -f "${SHARED_DIR}/RESOURCE_GROUP" ]
  then
    # service-instance-delete uses a CRN
    RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP")
    cleanup_ibmcloud_powervs "${RESOURCE_GROUP}"
    ic resource service-instance-delete "${POWERVS_SERVICE_INSTANCE_ID}" -g "${RESOURCE_GROUP}" --force --recursive \
      || true
  else
    echo "WARNING: No RESOURCE_GROUP or POWERVS_SERVICE_INSTANCE_ID found, not deleting the workspace"
  fi
fi

echo "IBM Cloud PowerVS resources destroyed successfully $(date)"