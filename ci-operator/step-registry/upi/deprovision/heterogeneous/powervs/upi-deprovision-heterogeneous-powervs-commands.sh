#!/bin/bash

# var.tfvars used to provision the powervs nodes is copied to the ${SHARED_DIR}
echo "Invoking upi deprovision heterogeneous powervs"

IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
mkdir -p "${IBMCLOUD_HOME_FOLDER}"
REGION="${LEASED_RESOURCE}"

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

echo "Check if the var.tfvars exists in ${SHARED_DIR}"
if [ -f "${SHARED_DIR}/var.tfvars" ]
then
  # upgrade go to GO_VERSION
  if [ -z "$(command -v go)" ]
  then
    echo "go is not installed, proceed to installing go"
    cd /tmp && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
      && tar -C /tmp -xzf "go${GO_VERSION}.linux-amd64.tar.gz" \
      && export PATH=$PATH:/tmp/go/bin && export GOCACHE=/tmp/go && export GOPATH=/tmp/go && export GOMODCACHE="/tmp/go/pkg/mod"
    if [ -z "$(command -v go)" ]
    then
      echo "Installed go successfully"
    fi
  fi

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
      --dest-dir ${ARTIFACT_DIR}/must-gather-ppc64le > ${ARTIFACT_DIR}/must-gather-ppc64le/must-gather-ppc64le.log
  tar -czC "${ARTIFACT_DIR}/must-gather-ppc64le" -f "${ARTIFACT_DIR}/must-gather-ppc64le.tar.gz" .
  rm -rf "${ARTIFACT_DIR}"/must-gather-ppc64le

  # build terraform
  cd "${IBMCLOUD_HOME_FOLDER}" \
    && curl -L "https://github.com/hashicorp/terraform/archive/refs/tags/v${TERRAFORM_VERSION}.tar.gz" \
      -o "${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz" \
    && tar -xzf "${IBMCLOUD_HOME_FOLDER}/terraform.tar.gz" \
    && cd "${IBMCLOUD_HOME_FOLDER}/terraform-${TERRAFORM_VERSION}" \
    && go build -ldflags "-w -s -X 'github.com/hashicorp/terraform/version.dev=no'" -o bin/ . \
    && cp bin/terraform /tmp/terraform
  export PATH=$PATH:/tmp
  t_ver1=$(/tmp/terraform -version)
  echo "terraform version: ${t_ver1}"

  echo "Destroy the terraform"
  OCP_VERSION=$(cat "${SHARED_DIR}/OCP_VERSION")
  # Fetch the ocp4-upi-compute-powervs repo to perform deprovisioning
  cd "${IBMCLOUD_HOME_FOLDER}" && curl -L "https://github.com/IBM/ocp4-upi-compute-powervs/archive/refs/heads/release-${OCP_VERSION}.tar.gz" -o "${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz" \
      && tar -xzf "${IBMCLOUD_HOME_FOLDER}/ocp-${OCP_VERSION}.tar.gz" \
      && mv "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs-release-${OCP_VERSION}" "${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs"
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
    && /tmp/terraform init -upgrade -no-color \
    && /tmp/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
    || sleep 30 \
    || /tmp/terraform destroy -var-file=data/var.tfvars -auto-approve -no-color \
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
    ic resource service-instance-delete "${POWERVS_SERVICE_INSTANCE_ID}" -g "${RESOURCE_GROUP}" --force --recursive \
      || true
  else
    echo "WARNING: No RESOURCE_GROUP or POWERVS_SERVICE_INSTANCE_ID found, not deleting the workspace"
  fi
fi

# Report the straggler workspaces with tag 'mac-power-worker'
EXTRA_CRNS=$(ic resource search "tags:\"mac-power-worker\"" --output json | jq -r '.items[].crn')
echo "Checking the Straggler Workspaces: "
echo "${EXTRA_CRNS}"
for T_CRN in ${EXTRA_CRNS//'\n'/ }
do
  echo "-Straggler Workspace: ${T_CRN}"
  ic pi st "${T_CRN}"

  echo "-- Cloud Connection --"
  ic pi cons --json | jq -r '.cloudConnections[] | .name,.cloudConnectionID' || true

  echo "-- Network --"
  ic pi nets

  # Rare case when no volumes or instances are ever created in the workspace.
  echo "-- Volumes --"
  ic pi vols || true

  echo "-- Instances --"
  ic pi ins || true

  COUNT_INS=$(ibmcloud pi ins --json | jq -r '.pvmInstances[]' | wc -l)
  COUNT_NETS=$(ibmcloud pi nets --json | jq -r '.networks[]' | wc -l)
  TOTAL=$((COUNT_INS + COUNT_NETS))

  echo "TOTAL RESOURCES: ${TOTAL}"
  RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP")
  ic resource service-instance-delete "${T_CRN}" -g "${RESOURCE_GROUP}" --force --recursive \
    || true

  echo "-- Gateway --"
  echo "TIP: only delete your gateway"
  ic tg gateways
done
echo "Done Checking"
echo "IBM Cloud PowerVS resources destroyed successfully"