#!/bin/bash
set -euo pipefail
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM
trap 'prepare_next_steps' EXIT TERM INT

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=/tmp:${PATH}

INSTALL_DIR=/tmp/installer
mkdir ${INSTALL_DIR}

function backoff() {
    local attempt=0
    local failed=0
    while true; do
        "$@" && failed=0 || failed=1
        if [[ $failed -eq 0 ]]; then
            break
        fi
        attempt=$(( attempt + 1 ))
        if [[ $attempt -gt 5 ]]; then
            break
        fi
        echo "command failed, retrying in $(( 2 ** $attempt )) seconds"
        sleep $(( 2 ** $attempt ))
    done
    return $failed
}

function populate_artifact_dir()
{
  set +e
  current_time=$(date +%s)

  echo "Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${INSTALL_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"

  # terraform may not exist now
  if [ -f "${INSTALL_DIR}/terraform.txt" ]; then
    sed -i '
      s/password: .*/password: REDACTED/;
      s/X-Auth-Token.*/X-Auth-Token REDACTED/;
      s/UserData:.*,/UserData: REDACTED,/;
      ' "${INSTALL_DIR}/terraform.txt"
    tar -czvf "${ARTIFACT_DIR}/terraform-${current_time}.tar.gz" --remove-files "${INSTALL_DIR}/terraform.txt"
  fi

  # Copy CAPI-generated artifacts if they exist
  if [ -d "${INSTALL_DIR}/.clusterapi_output" ]; then
    echo "Copying Cluster API generated manifests..."
    mkdir -p "${ARTIFACT_DIR}/clusterapi_output-${current_time}"
    cp -rpv "${INSTALL_DIR}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/clusterapi_output-${current_time}" 2>/dev/null
  fi
  set -e
}

function prepare_next_steps() {
  set +e
  populate_artifact_dir

  echo "Copying required artifacts to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"
  set -e
}


GATHER_BOOTSTRAP_ARGS=

function gather_bootstrap_and_fail() {
  if test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${INSTALL_DIR} gather bootstrap --key "${SSH_PRIVATE_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi

  return 1
}

function run_command_with_retries()
{
    local try=0 cmd="$1" retries="${2:-}" ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}'"

    eval "${cmd}" || ret=$?
    while [ X"${ret}" != X"0" ] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success, waiting 60 sec....."
        sleep 60
        try=$((try + 1))
        ret=0
        eval "${cmd}" || ret=$?
    done
    if [ ${try} -eq ${max} ]; then
        echo "Never succeed or Timeout"
        return 1
    fi
    echo "Succeed"
    return 0
}

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"
export TEST_PROVIDER='azure'

cp "$(command -v openshift-install)" /tmp

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

cp ${SHARED_DIR}/install-config.yaml ${INSTALL_DIR}/install-config.yaml
export PATH=${HOME}/.local/bin:${PATH}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
  echo "Setting AZURE credential with minimal permissions to install UPI"
  AZURE_AUTH_LOCATION="${SHARED_DIR}/azure_minimal_permission"
elif [[ -f "${SHARED_DIR}/azure-sp-contributor.json" ]]; then
  echo "Setting AZURE credential with Contributor role only to install UPI"
  export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure-sp-contributor.json
fi
export AZURE_AUTH_LOCATION

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

pushd ${INSTALL_DIR}

CLUSTER_NAME=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'metadata.name')
BASE_DOMAIN=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'baseDomain')
AZURE_REGION=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'platform.azure.region')
BASE_DOMAIN_RESOURCE_GROUP=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'platform.azure.baseDomainResourceGroupName')


SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
export CLUSTER_NAME
export BASE_DOMAIN

az_deployment_optional_parameters=""

provisioned_vnet_file="${SHARED_DIR}/customer_vnet_subnets.yaml"
if [ -f "${provisioned_vnet_file}" ]; then
    echo "vnet already created"
    vnet_name=$(yq-go r "${provisioned_vnet_file}" 'platform.azure.virtualNetwork')
    vnet_basename=$(echo "${vnet_name}" | sed 's/-vnet$//')
    az_deployment_optional_parameters="--parameters vnetBaseName=${vnet_basename}"
    [ -z "${vnet_basename}" ] && echo "Did not get vnet basename" && exit 1
fi

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
echo "Creating manifests"
openshift-install --dir=${INSTALL_DIR} create manifests

echo "Editing manifests"
sed -i '/^  channel:/d' manifests/cvo-overrides.yaml
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml
rm -f openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" manifests/cluster-scheduler-02-config.yml
sed -i "/publicZone/,+1d" manifests/cluster-dns-02-config.yml
sed -i "/privateZone/,+1d" manifests/cluster-dns-02-config.yml

if [ -v vnet_basename ] && [ -n "${vnet_basename}" ]; then
  echo "Editing vnet NSG from the existing vnet"
  installer_infraID=$(cat .openshift_install_state.json | jq -j '."*installconfig.ClusterID".InfraID')
  nsg_name="${vnet_basename}-nsg"
  sed -i "s/${installer_infraID}-nsg/${nsg_name}/g" manifests/cloud-provider-config.yaml
fi
popd

echo "Creating ignition configs"

openshift-install --dir=${INSTALL_DIR} create ignition-configs &
wait "$!"

cp ${INSTALL_DIR}/bootstrap.ign ${SHARED_DIR}
BOOTSTRAP_URI="https://${JOB_NAME_SAFE}-bootstrap-exporter-${NAMESPACE}.svc.ci.openshift.org/bootstrap.ign"
export BOOTSTRAP_URI
# begin bootstrapping

mkdir -p /tmp/azure

# Copy sample UPI files
cp -r /var/lib/openshift-install/upi/azure/* /tmp/azure

echo "az version:"
az version

echo "Logging in with az"
AZURE_AUTH_CLIENT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .clientId)
AZURE_AUTH_CLIENT_SECRET=$(cat $AZURE_AUTH_LOCATION | jq -r .clientSecret)
AZURE_AUTH_TENANT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .tenantId)
AZURE_SUBSCRIPTION_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .subscriptionId)
az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p "$AZURE_AUTH_CLIENT_SECRET" --tenant $AZURE_AUTH_TENANT_ID --output none
az account set --subscription ${AZURE_SUBSCRIPTION_ID}

echo ${AZURE_SUBSCRIPTION_ID} >> ${SHARED_DIR}/AZURE_SUBSCRIPTION_ID
echo ${AZURE_AUTH_CLIENT_ID} >> ${SHARED_DIR}/AZURE_AUTH_CLIENT_ID
echo ${AZURE_AUTH_CLIENT_SECRET} >> ${SHARED_DIR}/AZURE_AUTH_CLIENT_SECRET
echo ${AZURE_AUTH_TENANT_ID} >> ${SHARED_DIR}/AZURE_AUTH_TENANT_ID

INFRA_ID="$(jq -r .infraID ${INSTALL_DIR}/metadata.json)"
RESOURCE_GROUP="${INFRA_ID}-rg"
echo "Infra ID: ${INFRA_ID}"

provisioned_rg_file="${SHARED_DIR}/resourcegroup"
if [ -f "${provisioned_rg_file}" ]; then
  RESOURCE_GROUP=$(cat "${provisioned_rg_file}")
  echo "Using an existing resource group: ${RESOURCE_GROUP}"
else
  echo "Creating resource group ${RESOURCE_GROUP}"
  az group create --name $RESOURCE_GROUP --location $AZURE_REGION
fi

ACCOUNT_NAME=$(echo ${CLUSTER_NAME}sa | tr -cd '[:alnum:]')

echo "Creating storage account"
run_command_with_retries "az storage account create -g $RESOURCE_GROUP --location $AZURE_REGION --name $ACCOUNT_NAME --kind Storage --sku Standard_LRS" "5"
ACCOUNT_KEY=$(az storage account keys list -g $RESOURCE_GROUP --account-name $ACCOUNT_NAME --query "[0].value" -o tsv)

if openshift-install coreos print-stream-json 2>/tmp/err.txt >/tmp/coreos.json; then
  VHD_URL="$(jq -r --arg arch "$(echo "$OCP_ARCH" | sed 's/amd64/x86_64/;s/arm64/aarch64/')" '.architectures[$arch]."rhel-coreos-extensions"."azure-disk".url' /tmp/coreos.json)"
else
  VHD_URL="$(jq -r .azure.url /var/lib/openshift-install/rhcos.json)"
fi

# change to use --account-key instead of --auth-mode login to avoid issue
# https://github.com/MicrosoftDocs/azure-docs/issues/53299
echo "Copying VHD image from ${VHD_URL}"
az storage container create --name vhd --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY

status="false"
while [ "$status" == "false" ]
do
  status=$(az storage container exists --account-name $ACCOUNT_NAME --name vhd --account-key $ACCOUNT_KEY -o tsv --query exists)
done

az storage blob copy start --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY --destination-container vhd --destination-blob "rhcos.vhd" --source-uri "$VHD_URL"
status="false"
while [ "$status" == "false" ]
do
  status=$(az storage blob exists --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY --container-name vhd --name "rhcos.vhd" -o tsv --query exists)
done

status="pending"
cmd_result=1
while [[ ${cmd_result} -eq 1 ]] || [[ "$status" == "pending" ]]
do
  cmd_result=0
  status=$(az storage blob show --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY --container-name vhd --name "rhcos.vhd" -o tsv --query properties.copy.status) || cmd_result=1
done
if [[ "$status" != "success" ]]; then
  echo "Error copying VHD image ${VHD_URL}"
  exit 1
fi

echo "Uploading bootstrap.ign"
az storage container create --name files --account-name $ACCOUNT_NAME
az storage blob upload --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY -c "files" -f "${INSTALL_DIR}/bootstrap.ign" -n "bootstrap.ign"

echo "Creating private DNS zone"
az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

# The file azure-sp-contributor.json only exists under SHARED_DIR on 4.19+
# On 4.19+, user-assigned identity is not requried.
if [[ ! -f "${SHARED_DIR}/azure-sp-contributor.json" ]]; then
    echo "Creating identity"
    az identity create -g $RESOURCE_GROUP -n ${INFRA_ID}-identity
    PRINCIPAL_ID=$(az identity show -g $RESOURCE_GROUP -n ${INFRA_ID}-identity --query principalId --out tsv)
    echo "Assigning 'Contributor' role to principal ID ${PRINCIPAL_ID}"
    RESOURCE_GROUP_ID=$(az group show -g $RESOURCE_GROUP --query id --out tsv)
    az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type "ServicePrincipal" --role 'Contributor' --scope "$RESOURCE_GROUP_ID"
fi

pushd /tmp/azure

if [ -v vnet_name ] && [ -n "${vnet_name}" ]; then
  echo "Using the existing existing ${vnet_name}"
else
  echo "Deploying 01_vnet"
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "01_vnet.json" \
    --parameters baseName="$INFRA_ID"
  vnet_name="${INFRA_ID}-vnet"
fi

echo "Linking VNet to private DNS zone"
az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${INFRA_ID}-network-link -v "${vnet_name}" -e false

echo "Deploying 02_storage"
VHD_BLOB_URL=$(az storage blob url --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY -c vhd -n "rhcos.vhd" -o tsv)

# Check if it's the new template using Image Galleries instead of Managed Images
if grep -qs "Microsoft.Compute/galleries" 02_storage.json; then
  AZ_ARCH=$(echo "$OCP_ARCH" | sed 's/amd64/x64/;s/arm64/Arm64/')
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "02_storage.json" \
    --parameters vhdBlobURL="${VHD_BLOB_URL}" \
    --parameters baseName="$INFRA_ID" \
    --parameters storageAccount="$ACCOUNT_NAME" \
    --parameters architecture="$AZ_ARCH"
else
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "02_storage.json" \
    --parameters vhdBlobURL="${VHD_BLOB_URL}" \
    --parameters baseName="$INFRA_ID"
fi

echo "Deploying 03_infra"
az deployment group create -g $RESOURCE_GROUP \
  --template-file "03_infra.json" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
  --parameters baseName="$INFRA_ID" ${az_deployment_optional_parameters}

set +e
PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-master-pip'] | [0].ipAddress" -o tsv)
while [[ "$PUBLIC_IP" == "" ]]; do
  sleep 10;
  PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-master-pip'] | [0].ipAddress" -o tsv)
done
set -e

echo "Creating 'api' record in public zone for IP ${PUBLIC_IP}"
az network dns record-set a add-record -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} -n api.${CLUSTER_NAME} -a $PUBLIC_IP --ttl 60

echo "Deploying 04_bootstrap"
BOOTSTRAP_URL_EXPIRY=$(date -u -d "10 hours" '+%Y-%m-%dT%H:%MZ')
BOOTSTRAP_URL=$(az storage blob generate-sas -c 'files' -n 'bootstrap.ign' --https-only --full-uri --permissions r --expiry ${BOOTSTRAP_URL_EXPIRY} --account-name ${ACCOUNT_NAME} --account-key ${ACCOUNT_KEY} -o tsv)
#BOOTSTRAP_URL=$(az storage blob url --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv)
IGNITION_VERSION=$(jq -r .ignition.version ${INSTALL_DIR}/bootstrap.ign)
BOOTSTRAP_IGNITION=$(jq -rcnM --arg v "${IGNITION_VERSION}" --arg url $BOOTSTRAP_URL '{ignition:{version:$v,config:{replace:{source:$url}}}}' | base64 -w0)
# shellcheck disable=SC2046
az deployment group create -g $RESOURCE_GROUP \
  --template-file "04_bootstrap.json" $([ -n "${BOOTSTRAP_NODE_TYPE}" ] && echo "--parameters bootstrapVMSize=${BOOTSTRAP_NODE_TYPE}") \
  --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
  --parameters sshKeyData="$SSH_PUB_KEY" \
  --parameters baseName="$INFRA_ID" ${az_deployment_optional_parameters}

BOOTSTRAP_PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-bootstrap-ssh-pip'] | [0].ipAddress" -o tsv)
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_PUBLIC_IP}"

echo "Deploying 05_masters"
MASTER_IGNITION=$(cat ${INSTALL_DIR}/master.ign | base64 -w0)
# shellcheck disable=SC2046
az deployment group create -g $RESOURCE_GROUP \
  --template-file "05_masters.json" $([ -n "${CONTROL_PLANE_NODE_TYPE}" ] && echo "--parameters masterVMSize=${CONTROL_PLANE_NODE_TYPE}") \
  --parameters masterIgnition="$MASTER_IGNITION" \
  --parameters sshKeyData="$SSH_PUB_KEY" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
  --parameters baseName="$INFRA_ID" ${az_deployment_optional_parameters}

#on az version previouse to 2.45.0, property name is privateIpAddress
#on 2.45.0+, it changes to privateIPAddress
ip_keys='"privateIpAddress","privateIPAddress"'
MASTER0_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-0-nic --name pipConfig | jq -r "with_entries(select(.key | IN($ip_keys))) | .[]")
MASTER1_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-1-nic --name pipConfig | jq -r "with_entries(select(.key | IN($ip_keys))) | .[]")
MASTER2_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-2-nic --name pipConfig | jq -r "with_entries(select(.key | IN($ip_keys))) | .[]")
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master ${MASTER0_IP} --master ${MASTER1_IP} --master ${MASTER2_IP}"

echo "Deploying 06_workers"
WORKER_IGNITION=$(cat ${INSTALL_DIR}/worker.ign | base64 -w0)
export WORKER_IGNITION
# shellcheck disable=SC2046
az deployment group create -g $RESOURCE_GROUP \
  --template-file "06_workers.json" $([ -n "${COMPUTE_NODE_TYPE}" ] && echo "--parameters nodeVMSize=${COMPUTE_NODE_TYPE}") \
  --parameters workerIgnition="$WORKER_IGNITION" \
  --parameters sshKeyData="$SSH_PUB_KEY" \
  --parameters baseName="$INFRA_ID" ${az_deployment_optional_parameters}

popd
echo "Waiting for bootstrap to complete"
openshift-install --dir=${INSTALL_DIR} wait-for bootstrap-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!" || gather_bootstrap_and_fail

echo "Bootstrap complete, destroying bootstrap resources"
if [ ! -v nsg_name ]; then
    nsg_name=${INFRA_ID}-nsg
fi
az network nsg rule delete -g $RESOURCE_GROUP --nsg-name ${nsg_name} --name bootstrap_ssh_in
az vm stop -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap --skip-shutdown
az vm deallocate -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap
az vm delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap --yes
az disk delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap_OSDisk --no-wait --yes
az network nic delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-nic
az storage blob delete --account-key $ACCOUNT_KEY --account-name $ACCOUNT_NAME --container-name files --name bootstrap.ign
az network public-ip delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-ssh-pip

export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig

echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
function approve_csrs() {
  while [[ ! -f /tmp/install-complete ]]; do
      # even if oc get csr fails continue
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
  done
}
approve_csrs &

echo "Adding ingress DNS records"
## Wait for the default-router to have an external ip...(and not <pending>)
echo "$(date -u --rfc-3339=seconds) - Waiting for the default-router to have an external ip..."
set +e
public_ip_router="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
max_retries=30
try=0
while [[ "$public_ip_router" == "" || "$public_ip_router" == "<pending>" ]] && [ ${try} -lt ${max_retries} ]; do
  sleep 30;
  (( try++ ))
  public_ip_router="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
done
set -e

az network dns record-set a add-record -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} -n *.apps.${CLUSTER_NAME} -a $public_ip_router --ttl 300

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $public_ip_router


set +x
echo "Completing UPI setup"
openshift-install --dir=${INSTALL_DIR} wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"
touch /tmp/install-complete
