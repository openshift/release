#!/bin/bash

##### Constants
IBMCLOUD_HOME=/tmp/ibmcloud
export IBMCLOUD_HOME

export PATH=$PATH:/tmp:"${IBMCLOUD_HOME}"

# Variables
# OCP Version
if [ ! -f "${SHARED_DIR}/OCP_VERSION" ]
then
    echo "Provisioning never happened"
    exit 0
fi

OCP_VERSION=$(cat "${SHARED_DIR}/OCP_VERSION")
CLEAN_VERSION=$(echo "${OCP_VERSION}" | tr '.' '-')

# Region
REGION="${LEASED_RESOURCE}"
export REGION

# Workspace name
WORKSPACE_NAME="multi-arch-x-px-${REGION}-1"
export WORKSPACE_NAME

RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP")
export RESOURCE_GROUP

# Cleans up the failed prior jobs
function cleanup_ibmcloud_powervs() {
    echo "Cleaning up prior runs - version: ${CLEAN_VERSION} - workspace_name: ${WORKSPACE_NAME}"

    POWERVS_REGION=$(cat "${SHARED_DIR}/POWERVS_REGION")
    echo "VPC Region is ${REGION}"
    echo "PowerVS region is ${POWERVS_REGION}"

    # Delete the current TGW VPC Connection from the static transit gateway
    echo "Clean up transit gateway - VPC connection"
    RESOURCE_GROUP_ID=$(ibmcloud resource groups --output json | jq -r '.[] | select(.name == "'${RESOURCE_GROUP}'").id')
    echo ":started searching for gateway... output expected:"
    for GW in $(ibmcloud tg gateways --output json | jq --arg resource_group "${RESOURCE_GROUP_ID}" --arg name "multi-arch-x-px-${POWERVS_REGION}-1-tg" -r '.[] | select(.resource_group.id == $resource_group) | select(.name == $name) | .id')
    do
        echo ":gateway: ${GW}"
        VPC_NAME_PREFIX=$(yq-v4 -r '.metadata.name' "${SHARED_DIR}/install-config.yaml")
        for VPC_NAME in $(ibmcloud is vpcs --output json | jq -r --arg mn "${VPC_NAME_PREFIX}" '.[] | select(.name | contains($mn)).name')
        do
            echo ":VPC: ${VPC_NAME}"
            VPC_CONN_ID="$(ibmcloud tg connections "${GW}" 2>&1 | grep "${VPC_NAME}-vpc" | awk '{print $3}')"
            if [ -n "${VPC_CONN_ID}" ]
            then
                echo "deleting VPC connection"
                ibmcloud tg connection-delete "${GW}" "${CS}" --force || true
                sleep 120
                echo "Done Cleaning up GW VPC Connection"
            else
                echo "GW VPC Connection not found. VPC Cleanup not needed."
            fi
        done
    done

    echo "reporting out the remaining TGs in the resource_group and region"
    ibmcloud tg gws --output json | jq -r '.[] | select(.resource_group.id == "'$RESOURCE_GROUP_ID'" and .location == "'$REGION'")'

    echo "Cleaning up workspaces for ${WORKSPACE_NAME}"
    for CRN in $(ibmcloud pi workspace ls 2> /dev/null | grep "${WORKSPACE_NAME}" | awk '{print $1}')
    do
        echo "Targetting power cloud instance"
        ibmcloud pi workspace target "${CRN}"

        echo "Deleting the PVM Instances"
        for INSTANCE_ID in $(ibmcloud pi instance ls --json | jq -r '.pvmInstances[] | .id')
        do
        echo "Deleting PVM Instance ${INSTANCE_ID}"
        ibmcloud pi instance delete "${INSTANCE_ID}" --delete-data-volumes
        sleep 60
        done

        if [ -n "$(ibmcloud pi nets 2> /dev/null | grep DHCP)" ]
        then
        curl -L -o /tmp/pvsadm "https://github.com/ppc64le-cloud/pvsadm/releases/download/v0.1.12/pvsadm-linux-amd64"
        chmod +x /tmp/pvsadm

        POWERVS_SERVICE_INSTANCE_ID=$(echo "${CRN}" | sed 's|:| |g' | awk '{print $NF}')

        NET_ID=$(IC_API_KEY="@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" /tmp/pvsadm dhcpserver list --instance-id ${POWERVS_SERVICE_INSTANCE_ID} --skip_headers --one_output | awk '{print $2}' | grep -v ID | grep -v '|' | sed '/^$/d' || true)
        IC_API_KEY="@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" /tmp/pvsadm dhcpserver delete --instance-id ${POWERVS_SERVICE_INSTANCE_ID} --id "${NET_ID}" || true
        sleep 60
        fi

        echo "Deleting the Network"
        for NETWORK_ID in $(ibmcloud pi network ls 2> /dev/null | awk '{print $1}')
        do
        echo "Deleting network ${NETWORK_ID}"
        ibmcloud pi network delete "${NETWORK_ID}" || true
        sleep 60
        done
    done
    echo "Done cleaning up prior runs"
}

# var.tfvars used to provision the powervs nodes is copied to the ${SHARED_DIR}
echo "Invoking upi deprovision heterogeneous powervs for ${WORKSPACE_NAME}"

mkdir -p "${IBMCLOUD_HOME}"

if [ -z "$(command -v ibmcloud)" ]
then
  echo "ibmcloud CLI doesn't exist, installing"
  curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
fi

ibmcloud version
ibmcloud login --apikey "@${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -r "${REGION}"
ibmcloud plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas is tg-cli

echo "Check if the terraform.tfstate exists in ${SHARED_DIR}"
if [ -f "${SHARED_DIR}/terraform.tfstate" ]
then
  # The must-gather chain can not be called twice, as the ibmcloud embeds must-gather in deprovision
  # we must call must-gather specific to ppc64le at this location.
  MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"15m"}
  MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-""}
  oc get nodes -l kubernetes.io/arch=ppc64le -o yaml > "${ARTIFACT_DIR}"/nodes_with_ppc64le.txt || true

  # Download the MCO sanitizer binary from mirror
  curl -sL "https://mirror.openshift.com/pub/ci/$(arch)/mco-sanitize/mco-sanitize" > /tmp/mco-sanitize
  chmod +x /tmp/mco-sanitize

  mkdir -p ${ARTIFACT_DIR}/must-gather-ppc64le
  oc adm must-gather \
      --node-selector=kubernetes.io/arch=ppc64le \
      --insecure-skip-tls-verify $MUST_GATHER_IMAGE \
      --timeout=$MUST_GATHER_TIMEOUT \
      --dest-dir ${ARTIFACT_DIR}/must-gather-ppc64le > ${ARTIFACT_DIR}/must-gather-ppc64le/must-gather-ppc64le.log \
      || true
  
  
  # Sanitize MCO resources to remove sensitive information.
  # If the sanitizer fails, fall back to manual redaction.
  if ! /tmp/mco-sanitize --input="${ARTIFACT_DIR}/must-gather-ppc64le"; then
    find "${ARTIFACT_DIR}/must-gather-ppc64le" -type f -path '*/cluster-scoped-resources/machineconfiguration.openshift.io/*' -exec sh -c 'echo "REDACTED" > "$1" && mv "$1" "$1.redacted"' _ {} \;
  fi   
  
  tar -czC "${ARTIFACT_DIR}/must-gather-ppc64le" -f "${ARTIFACT_DIR}/must-gather-ppc64le.tar.gz" .
  rm -rf "${ARTIFACT_DIR}"/must-gather-ppc64le

  # short-circuit to download and install terraform
  curl -o "${IBMCLOUD_HOME}"/terraform.gz -L https://releases.hashicorp.com/terraform/"${TERRAFORM_VERSION}"/terraform_"${TERRAFORM_VERSION}"_linux_amd64.zip \
    && gunzip "${IBMCLOUD_HOME}"/terraform.gz \
    && chmod +x "${IBMCLOUD_HOME}"/terraform \
    || true

  "${IBMCLOUD_HOME}"/terraform -version -json

  echo "Destroy the terraform"
  # Fetch the ocp4-upi-compute-powervs repo to perform deprovisioning
  cd "${IBMCLOUD_HOME}" && curl -L "https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/main.tar.gz" -o "${IBMCLOUD_HOME}/ocp-${OCP_VERSION}.tar.gz" \
      && tar -xzf "${IBMCLOUD_HOME}/ocp-${OCP_VERSION}.tar.gz" \
      && mv "${IBMCLOUD_HOME}/ocp4-upi-compute-powervs-main" "${IBMCLOUD_HOME}/ocp4-upi-compute-powervs"
  # copy the var.tfvars file from ${SHARED_DIR}
  cp "${SHARED_DIR}/var.tfvars" ${IBMCLOUD_HOME}/ocp4-upi-compute-powervs/data/var.tfvars
  cp "${SHARED_DIR}/terraform.tfstate" ${IBMCLOUD_HOME}/ocp4-upi-compute-powervs/terraform.tfstate

  # Copy over the key files and kubeconfig
  export PRIVATE_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  export PUBLIC_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-publickey"
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  cp "${PUBLIC_KEY_FILE}" "${IBMCLOUD_HOME}/ocp4-upi-compute-powervs/data/id_rsa.pub"
  cp "${PRIVATE_KEY_FILE}" "${IBMCLOUD_HOME}/ocp4-upi-compute-powervs/data/id_rsa"
  cp "${KUBECONFIG}" "${IBMCLOUD_HOME}/ocp4-upi-compute-powervs/data/kubeconfig"

  # Invoke the destroy command
  cd "${IBMCLOUD_HOME}/ocp4-upi-compute-powervs" \
    && "${IBMCLOUD_HOME}"/terraform init -upgrade -no-color \
    && "${IBMCLOUD_HOME}"/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
    || sleep 30 \
    || "${IBMCLOUD_HOME}"/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
    || true
else
  echo "Error: File ${SHARED_DIR}/var.tfvars does not exists."
fi

# Delete the workspace created
if [ -f "${SHARED_DIR}/POWERVS_SERVICE_CRN" ]
then
  cleanup_ibmcloud_powervs
else
  echo "WARNING: No RESOURCE_GROUP or POWERVS_SERVICE_INSTANCE_ID found, not deleting the workspace"
fi

echo "IBM Cloud PowerVS resources destroyed successfully $(date)"
